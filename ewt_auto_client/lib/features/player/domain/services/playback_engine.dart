/// 播放行为模拟引擎（状态机）：完整复刻浏览器看课链路——取 BFE 会话、播放 token、
/// 认真度检测（滑块/点选验证码）、约 60 秒心跳 collect 上报与 playbackProgress 进度持久化。
/// 支持普通播放、快刷（burst 多轮重刷）、重刷与补偿检测等多种模式。
library;

import 'dart:async';
import 'dart:math';

import '../../../../core/captcha/captcha_service.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/config/endpoint_config.dart';
import '../../../../core/constants/crypto_constants.dart';
import '../entities/serious_check_config.dart';
import '../entities/telemetry_context.dart';
import '../entities/video_session.dart';
import '../../data/datasources/player_remote_datasource.dart';
import '../../data/datasources/telemetry_remote_datasource.dart';

/// 播放行为模拟引擎（状态机）
///
/// 对应 Python: tasks/player_behavior.py PlayerBehaviorTask
/// 对齐 `debug/player_behavior/mstplayer_behavior_doc.md` 与
///       `debug/player_behavior/mstplayer_seriousness_check_doc.md`
///
/// 完整行为链:
/// 1. getPlayerGlobalConf → sessionId + secret + clientIp
/// 2. getVideodp → 黑名单状态 (决定认真度检测走滑块型还是确认型)
/// 3. getSeriousCheckDownGradeConfig → 降级配置
/// 4. getPlayerToken → videoToken
/// 5. getExternalVideoInfo → 时长 + 互动点 (可失败, 不阻断)
/// 6. 客户端生成 videoCheckPoint 检测点数组 (基于时长和互动点位置, §3'.1.2)
/// 7. record/submit → 标记开始观看 (processTime=续刷起点 or 0)
/// 8. 起始 burst (act=2,1,3,2)
/// 9. 心跳循环 (墙钟固定 60s/120s, 不随 speed 缩短)
///    - 认真度检测点到达时: act=3 → 非黑名单 addVideoss(0) / 黑名单 addVideocss(0) →
///      主动解算滑块(仅黑名单) → 二次上报(2,token) → act=2
///    - playbackProgress 周期/事件触发
/// 10. 结束 burst (余量心跳 + act=3 + act=4)
/// 11. 最终 playbackProgress 2+1 (2 在 act=4 前, 1 在 act=4 后)
///
/// 快刷模式:
/// - 真实短等待 + 大 media_time (模拟前向 seek)
/// - 多轮重刷直到真实进度 ≥ completeRatio (默认 0.8, 由配置传入)
/// - 30s 循环内进度轮询, 达标提前结束 (realProgressQuery=true 时)
/// - 续刷: 从服务端已完成 playTime 处继续, 不重头刷
///
/// 互动视频:
/// - getExternalVideoInfo.interactiveInfo.interactiveConfigList
/// - getInteractiveConfigDetail → interactiveSceneId + question.id
/// - submitAnswer 空答取正确答案 → submitAnswer 正确答案
/// - 非黑名单 addVideoss(type=3) / 黑名单 addVideocss(type=3) 记录互动点通过
/// - refreshTaskProgress 刷新任务进度
class PlaybackEngine {
  final PlayerRemoteDataSource _playerRemote;
  final TelemetryRemoteDataSource _telemetryRemote;
  final EndpointConfig _endpointConfig;

  final _progressController = StreamController<PlaybackProgress>.broadcast();
  bool _cancelled = false;
  final _random = Random();

  // 运行时参数（由 simulatePlayback 设置）
  int _heartbeatInterval = 60;
  double _speed = 1.0;
  double _completeRatio = 0.80;
  // 真实进度轮询间隔 (秒, 由配置传入, 默认 60)
  int _progressPollInterval = 60;
  // 快刷并发线程数 (对一个课程同时发包的线程数, 静态 burst)
  int _fastBrushThreads = 10;
  // 真实进度查询开关 (默认 true)
  // true: 周期性查询服务端真实进度, 达 _completeRatio 提前结束当前任务
  // false: 不查询服务端真实进度, 使用本地模拟进度跑完整个播放循环
  bool _realProgressQuery = true;

  // 最大重刷轮数 (burst 模式多轮重刷, 0=自动估算)
  int _fastBrushMaxRounds = 0;
  // 服务端限流退避基数 (ms), 指数退避 = base * 2^(连续失败次数)
  int _fastBrushWafBackoff = 2000;
  // 每次心跳并发 collect 包数 (0=自动=min(200, 10+线程数))
  int _fastBrushEventsPerRequest = 0;
  // 服务端 maxBatchSize (getPlayerGlobalConf.globalInfo.maxBatchSize):
  // 每请求事件数 = 0(自动) 时使用的打包数, 对齐 Python `_resolve_multi` 的
  // `self.conf.get("maxBatchSize", ...)` 兜底逻辑, 取不到时默认 10。
  int _maxBatchSize = 10;
  // 单事件停留时长 (ms), 仅快刷模式生效
  int _fastBrushStayTime = 10000;
  // 轮次间真实等待/轮询间隔 (秒), 仅快刷模式生效
  int _fastBrushPollInterval = 10;
  // 重刷模式(刷时长): 每课固定轮数, 每轮目标 = 服务器已刷时长 + 额外分钟
  bool _rebrush = false;
  int _rebrushRounds = 1;
  int _rebrushExtraMinutes = 40;
  // 重刷模式当前轮的目标 playTime(ms), 0 表示非重刷模式 (普通快刷/正常)
  int _rebrushTargetMs = 0;
  // 补偿检测模式: 仅补偿认真度/互动点上报, 不刷进度
  bool _compensate = false;

  // 当前会话引用 (供 setSpeed / reportSeek 动态更新)
  VideoSession? _session;

  // 会话级遥测状态（对应 Python _execute_begin_ts / _uuid_prefix / _uuid_seq 等）
  int _beginTs = 0;
  String _uuidPrefix = '';
  int _uuidSeq = 0;
  int _pointNum = 1;
  int _lastPti = 0;
  double _ptiFloat = 0.0;
  int _playedS = 0;
  int _heartbeatOkCount = 0;
  int _collectFailCount = 0;

  // 客户端生成的检测点数组 (对齐 §3'.1.2 videoCheckPoint)
  List<int> _videoCheckPoints = const [];

  // 已完成的认真度检测点数 (用于 UI 显示 "已完成/全部检测点")
  int _completedCheckPointCount = 0;

  // 互动点总数 (来自 session.interactiveConfigs.length, 用于 UI 显示 "已完成/全部互动点")
  int _interactiveTotalCount = 0;

  // 已完成的互动点数 (用于 UI 显示 "已完成/全部互动点")
  int _interactiveDoneCount = 0;

  // 快刷多轮状态
  //
  // _fastBrush: 快刷模式总开关 (对齐 Python `_execute_fast_brush`):
  //   由 simulatePlayback(fastMode=true) 设置, 与 _maxRounds 解耦,
  //   用于 _runCourseSession 内部判定走 _fastBrushLoop 还是 _normalHeartbeatLoop。
  //   避免 _maxRounds=0 (自动估算) 时首轮误判为正常模式。
  bool _fastBrush = false;
  // 快刷模式2: 多 session 预算乘法 (限速预算键 = 客户端可控的
  // x-bfe-session-id, 每个 session 独立核算信用, 可 mint 放大)
  bool _fastBrush2 = false;
  // 快刷模式2 每轮铸造的 session 数 (1~50, 默认 8)
  int _fastBrushSessions = 8;
  bool _lessonFocusDone = false;
  bool _lessonInteractiveDone = false;
  // 预算感知节流: 连续多轮无入账判定为预算耗尽 → 提前结束当前课时
  // (避免 interval 拉到 30s 后仍 0 入账造成"进度根本不加"的卡死观感,
  //  直接结束让批量流程跳到下一课时)
  bool _budgetExhausted = false;
  int _resumePlaytimeMs = 0;
  int _brushRounds = 0;
  double _brushFinalRatio = 0.0;

  /// 快刷/快刷2: 本轮任务真实进度是否已达完成阈值 (真实进度查询开启时有效)
  ///
  /// 用于收尾判定: 未达标时不得标记任务完成 (防止轮数耗尽时 ~60% 进度
  /// 被错误标记"播放完成")。
  bool _brushTargetMet = false;

  // 是否从上次进度开始 (默认 true)
  // false 时: 快刷模式首轮强制从 0 开始, 不读取服务端 playTime 作为起点
  //          (后续轮次仍会读取 playTime 用于判断是否完成, 但不作为续刷起点)
  // true 时: 快刷模式首轮即从服务端 playTime 续刷 (原有行为)
  bool _resumeFromServer = true;

  // 备用上报通道配置 (由 simulatePlayback 设置, 透传到 sendCollectBatch)
  // _useBackup=true 时跳过 bfe 主通道, 直接使用 _reportBackend 指定的通道
  // _reportBackend: 'clog'/'dlog'/'iplog' (iplog 使用 fallbackIP 直连)
  bool _useBackup = false;
  String _reportBackend = 'clog';

  // 认真度检测降级配置 (进入会话时由 _initialize 获取)
  // isDowngrade==true 时, 检测点仅记录日志, 不执行 act=3 暂停 / 滑块 / addVideoss 打断
  SeriousCheckConfig _seriousCheckConfig = const SeriousCheckConfig();

  // 黑名单状态 (进入会话时由 getVideodp 获取)
  // isBlacklisted==true → 滑块型 (ek 组件, ecaptcha)
  // isBlacklisted==false → 确认型 (ev 组件, 仅点击"我知道了")
  bool _isBlacklisted = false;

  // 互动视频标记 (来自 getLessonDetailV2.interactiveVideo 或 getExternalVideoInfo)
  // 用于 addVideoss.type 字段映射: interactiveVideo ? 3 : (contentType==1 ? 1 : 2)
  bool _isInteractiveVideo = false;

  PlaybackEngine({
    required PlayerRemoteDataSource playerRemote,
    required TelemetryRemoteDataSource telemetryRemote,
    required EndpointConfig endpointConfig,
  })  : _playerRemote = playerRemote,
        _telemetryRemote = telemetryRemote,
        _endpointConfig = endpointConfig;

  /// 进度事件流
  Stream<PlaybackProgress> get progressStream => _progressController.stream;

  /// 快刷统计 (刷完一轮后可读取)
  int get brushRounds => _brushRounds;
  double get brushFinalRatio => _brushFinalRatio;

  /// 服务器时间偏移 (ms) - 用于 UI 显示
  int get serverTimeDiffMs => _telemetryRemote.clock.diffMs;

  /// 服务器时间同步次数
  int get serverTimeSyncCount => _telemetryRemote.clock.syncCount;

  /// 服务器最后同步时间戳 (ms)
  int get serverLastTs => _telemetryRemote.clock.lastServerTs;

  /// 客户端生成的检测点数组
  List<int> get videoCheckPoints => List.unmodifiable(_videoCheckPoints);

  /// 已完成的认真度检测点数
  int get completedCheckPointCount => _completedCheckPointCount;

  /// 互动点总数
  int get interactiveTotalCount => _interactiveTotalCount;

  /// 已完成的互动点数
  int get interactiveDoneCount => _interactiveDoneCount;

  /// 黑名单状态
  bool get isBlacklisted => _isBlacklisted;

  /// 互动视频标记 (用于 addVideoss.type 字段映射)
  bool get isInteractiveVideo => _isInteractiveVideo;

  /// 认真度检测降级配置
  SeriousCheckConfig get seriousCheckConfig => _seriousCheckConfig;

  /// 心跳成功次数
  int get heartbeatOkCount => _heartbeatOkCount;

  /// 上报失败次数
  int get collectFailCount => _collectFailCount;

  /// 认真度检测是否全部通过
  bool get lessonFocusDone => _lessonFocusDone;

  /// 互动答题是否完成
  bool get lessonInteractiveDone => _lessonInteractiveDone;

  /// 当前已播放秒数
  int get playedSeconds => _playedS;

  /// 上次 point_time_id
  int get lastPointTimeId => _lastPti;

  /// 会话总检测点数
  int get pointNum => _pointNum;

  /// 当前心跳间隔 (秒, 用于 UI 估算总秒数)
  int get heartbeatInterval => _heartbeatInterval;

  /// 执行完整播放模拟
  ///
  /// [fastMode] 快速刷课模式（发送大 media_time 模拟快进）
  /// [heartbeatInterval] 心跳间隔（秒），覆盖 endpointConfig 默认值
  /// [speed] 播放倍速（写入 EventPackage.speed，正常模式默认 1.0，快刷默认 2.0）
  /// [fastBrushMaxRounds] 快刷最大重刷轮数 (0=自动估算)
  /// [completeRatio] 快刷完成阈值 (默认 0.8)
  /// [progressPollInterval] 真实进度轮询间隔 (秒, 默认 60, 5~600)
  /// [realProgressQuery] 是否查询服务端真实进度, 达阈值提前跳到下一任务 (默认 true)
  /// [useBackup]    是否启用备用上报通道 (跳过 bfe 主通道)
  /// [reportBackend] 备用通道: 'clog'/'dlog'/'iplog'
  /// [fastBrushThreads] 快刷并发线程数 (默认 10, 仅快刷模式生效)
  /// [fastBrushMaxRounds] 快刷最大重刷轮数 (0=自动估算, 仅快刷模式生效)
  /// [fastBrushWafBackoff] 服务端限流退避基数 ms (指数退避, 仅快刷模式生效)
  /// [fastBrushEventsPerRequest] 每请求打包事件数 (EventPackage 长度, 0=自动用服务端 maxBatchSize, 仅快刷模式生效)
  /// [maxBatchSize] 服务端 maxBatchSize (getPlayerGlobalConf), 每请求事件数=0 时使用
  /// [rebrush] 重刷模式(刷时长): 每课固定轮数, 每轮目标 = 服务器已刷时长 + [rebrushExtraMinutes] 分钟
  /// [rebrushRounds] 重刷模式每课最大轮数 (硬约束, 跑满即止)
  /// [rebrushExtraMinutes] 重刷模式每轮额外时长 (分钟, 默认 40)
  /// [compensate] 补偿检测模式: 仅补偿认真度/互动点上报, 不刷进度 (优先级最高)
  /// [fastBrush2] 快刷模式2: 多 session 预算乘法 (仅 fastMode/rebrush 时生效)
  /// [fastBrushSessions] 快刷模式2 每轮铸造 session 数 (1~50, 默认 8)
  /// 模拟播放主入口: 状态机编排一次完整播放会话
  ///
  /// 状态机总览 (单任务内):
  ///   1. 初始化运行时参数 (并发数/退避/轮数/补偿模式等, 见下方赋值)
  ///   2. 按模式分发: 重刷 → [_rebrushLoop] (基于普通模式行为链, 固定轮数刷时长),
  ///      快刷 → [_fastBrushBurstLoop] (静态 burst 并发 collect),
  ///      正常 → [_normalHeartbeatLoop] (单发心跳); 补偿模式独立
  ///   3. 每轮循环内: collect 上报 → WAF 退避判定 → 检测点/互动点触发 →
  ///      真实进度查询 → 达 [completeRatio] 提前结束
  ///   4. 异常路径: 认证失败抛 [AuthException], 风控命中抛 [RedlineException]
  ///
  /// [fastMode] 走快刷 burst 路径; [rebrush] 基于普通模式行为链 (单发心跳),
  /// 仅结束条件不同 (固定轮数 × 每轮目标时长), 见 [_rebrushLoop]。
  Future<void> simulatePlayback(
    VideoSession session, {
    bool fastMode = false,
    int? heartbeatInterval,
    double speed = 1.0,
    double completeRatio = 0.8,
    int progressPollInterval = 60,
    bool realProgressQuery = true,
    bool resumeFromServer = true,
    bool useBackup = false,
    String reportBackend = 'clog',
    int fastBrushThreads = 10,
    int fastBrushMaxRounds = 0,
    int fastBrushWafBackoff = 2000,
    int fastBrushEventsPerRequest = 0,
    int fastBrushStayTime = 10000,
    int fastBrushPollInterval = 10,
    int maxBatchSize = 10,
    bool rebrush = false,
    int rebrushRounds = 1,
    int rebrushExtraMinutes = 40,
    bool compensate = false,
    bool fastBrush2 = false,
    int fastBrushSessions = 8,
  }) async {
    _cancelled = false;
    // 重刷模式基于普通模式行为链 (单发心跳), 不再进入快刷 burst 路径
    _fastBrush = fastMode;
    _fastBrush2 = fastBrush2 && _fastBrush;
    _fastBrushSessions = fastBrushSessions.clamp(1, 50);
    _resumeFromServer = resumeFromServer;
    _realProgressQuery = realProgressQuery;
    _useBackup = useBackup;
    _reportBackend = reportBackend;
    _heartbeatInterval = heartbeatInterval ?? _endpointConfig.reportInterval;
    _speed = speed > 0 ? speed : 1.0;
    _completeRatio = completeRatio;
    _progressPollInterval = progressPollInterval.clamp(5, 600);
    if (fastMode && _fastBrushPollInterval > 0) {
      _progressPollInterval = _fastBrushPollInterval.clamp(5, 600);
    }
    _fastBrushThreads = fastBrushThreads.clamp(1, 50);
    _fastBrushMaxRounds = fastBrushMaxRounds;
    _fastBrushWafBackoff = fastBrushWafBackoff;
    _fastBrushEventsPerRequest = fastBrushEventsPerRequest;
    _fastBrushStayTime = fastBrushStayTime;
    _fastBrushPollInterval = fastBrushPollInterval;
    _maxBatchSize = maxBatchSize > 0 ? maxBatchSize : 10;
    _rebrush = rebrush;
    _rebrushRounds = rebrushRounds;
    _rebrushExtraMinutes = rebrushExtraMinutes;
    _rebrushTargetMs = 0;
    _compensate = compensate;
    _lessonFocusDone = false;
    _lessonInteractiveDone = false;
    _budgetExhausted = false;
    _brushRounds = 0;
    _brushFinalRatio = 0.0;
    _brushTargetMet = false;
    _collectFailCount = 0;
    _completedCheckPointCount = 0;
    _interactiveDoneCount = 0;
    _interactiveTotalCount = session.interactiveConfigs.length;
    _session = session;

    try {
      if (_compensate) {
        // 补偿检测模式: 仅补偿认真度/互动点上报, 不刷进度
        await _compensateLoop(session);
      } else if (_rebrush) {
        // 重刷模式(刷时长, 基于普通模式行为链): 单发心跳/正常倍速,
        // 差异仅在结束条件 — 每课固定轮数, 每轮目标 = 服务器已刷时长 + 额外分钟
        await _rebrushLoop(session);
      } else if (_fastBrush) {
        await _fastBrushBurstLoop(session);
      } else {
        // 正常模式: resumeFromServer=true 时查询服务端进度作为已上报起点
        int normalResumeMs = 0;
        if (_resumeFromServer && session.homeworkId.isNotEmpty) {
          try {
            final ratio = await _queryProgressRatio(session);
            normalResumeMs = _resumePlaytimeMs;
            _emit(session, PlaybackState.initializing,
                '续播: 服务端进度 ${(ratio * 100).toInt()}%, '
                'playTime=${normalResumeMs}ms');
          } catch (_) {}
        }
        await _runCourseSession(
          session,
          enableFocusCheck: true,
          resumePlaytimeMs: normalResumeMs,
        );
        // 互动点已在 _normalHeartbeatLoop 中按 interactiveTimePoint 触发,
        // 并在循环结束时兜底补齐 + _finalizeInteractive, 此处无需再调用。
      }

      if (!_compensate) {
        if (_cancelled) {
          // 用户取消: 如实标记取消, 不再错误标记任务完成
          _emit(session, PlaybackState.cancelled, '已取消');
        } else if (_fastBrush && _realProgressQuery && !_brushTargetMet) {
          // 快刷/快刷2: 完成必须以真实进度达阈值为准 —
          // 轮数耗尽仍未达标时如实标记失败, 不再错误标记任务完成
          // (修复: 自动轮数耗尽时进度仅 ~60% 却被标记"播放完成")
          _emit(session, PlaybackState.failed,
              '未达完成阈值 (${(_brushFinalRatio * 100).toInt()}% '
              '< ${(_completeRatio * 100).toInt()}%), 任务未标记完成');
        } else {
          session.isCompleted = true;
          _emit(session, PlaybackState.completed, '播放完成');
        }
      }
    } catch (e) {
      _emit(session, PlaybackState.failed, null, error: '$e');
      rethrow;
    }
  }

  /// 取消播放
  void cancel() {
    _cancelled = true;
  }

  /// 动态更新播放倍速 (用户在播放器中切换倍速时调用)
  ///
  /// 更新后, 后续心跳的 media_time 和 point_time_id 累积将使用新倍速。
  /// 对应 Web 播放器倍速切换事件: 重新设置 EventPackage.speed。
  void setSpeed(double s) {
    _speed = s > 0 ? s : 1.0;
  }

  /// 上报 seek 事件 (用户快进/快退/拖动进度条)
  ///
  /// 对应 Web 播放器 seek 事件: 发送一次 playbackProgress, 上报当前实际播放位置。
  /// 仅更新 session.playedTime 并持久化, 不影响引擎内部模拟节奏。
  Future<void> reportSeek(int positionSeconds) async {
    if (_cancelled || _session == null) return;
    _session!.playedTime = positionSeconds;
    await _persistProgress(_session!);
  }

  void dispose() {
    cancel();
    _session = null;
    _progressController.close();
  }

  // ─── 单轮会话 (正常/快刷共用) ───

  /// 刷一轮完整播放器行为链
  ///
  /// 对应 Python: _execute_course_session
  Future<void> _runCourseSession(
    VideoSession session, {
    bool enableFocusCheck = true,
    int resumePlaytimeMs = 0,
  }) async {
    // Stage 1: 初始化 (token / videoInfo / duration / courseId / 互动点 / 黑名单 / 降级配置)
    _emit(session, PlaybackState.initializing, '获取播放配置...');
    await _initialize(session);
    if (_cancelled) return;

    // 初始化会话级遥测状态
    _beginTs = _telemetryRemote.clock.now();
    _uuidPrefix = _genUuidPrefix();
    _uuidSeq = 0;
    _lastPti = 0;
    _ptiFloat = 0.0;
    _playedS = 0;
    _heartbeatOkCount = 0;
    // point_num = 视频总点数, 按服务端点间隔 intervalTime (60s) 计算,
    // 与心跳间隔 _heartbeatInterval 解耦:
    // 快刷模式心跳间隔可远小于 60s (如 10s), 若用其计算 point_num 会导致
    // 上报的 point_num 虚高 (如 119 vs 真实 20), 破坏服务端窗口语义。
    const serverPointInterval = 60; // 对齐 getPlayerGlobalConf.intervalTime
    _pointNum = max(
      1,
      (session.duration + serverPointInterval - 1) ~/ serverPointInterval,
    );

    _emit(session, PlaybackState.initializing,
        '会话初始化: beginTs=$_beginTs, uuid=$_uuidPrefix, '
        'pointNum=$_pointNum, serverTimeDiff=${_telemetryRemote.clock.diffMs}ms, '
        'syncCount=${_telemetryRemote.clock.syncCount}');

    // 续刷起点计算
    //
    // 快刷/重刷模式与正常模式统一: resumePlaytimeMs 来自服务端 playTime,
    // 作为已上报进度起点 (recordProcessMs) 传给 _startPlayback。
    //
    int recordProcessMs = 0;
    if (_fastBrush || _rebrush || _resumeFromServer) {
      final durMs = session.duration * 1000;
      recordProcessMs = resumePlaytimeMs.clamp(0, durMs);
    }

    // Stage 2: record/submit (开始观看, 续刷时携带已完成进度)
    _emit(session, PlaybackState.starting, '开始播放...');
    await _startPlayback(session, processTimeMs: recordProcessMs);
    if (_cancelled) return;

    // Stage 3: 起始 burst
    await _sendStartBurst(session);
    if (_cancelled) return;

    // Stage 4: 心跳循环
    _emit(session, PlaybackState.playing, '播放中...');
    if (_fastBrush) {
      await _fastBrushLoop(session, enableFocusCheck: enableFocusCheck);
    } else {
      await _normalHeartbeatLoop(session, enableFocusCheck: enableFocusCheck);
    }
    if (_cancelled) return;

    // Stage 5: 结束序列 (2 playprog + act=3 + act=4 + 1 playprog)
    _emit(session, PlaybackState.finishing, '完成中...');
    await _finishPlayback(session);
  }

  /// 快刷 burst 模式: 每轮完整播放 (普通心跳 + burst 并发 collect), 多轮重刷直至真实进度达标。
  ///
  /// 对应 Python: _execute_fast_brush_until_complete。轮数策略:
  /// - [fastBrushMaxRounds] = 0 (自动) 且真实进度查询开启: **不设轮数上限**,
  ///   刷到真实进度 ≥ 完成阈值为止 (受取消/预算耗尽保护)。旧估算公式
  ///   (completeRatio×speed×1.5, 下限 5) 严重低估快刷2每轮实际推进量
  ///   (受会话预算/延迟入账约束, 实测 ~6-12%/轮), 5 轮耗尽仅 ~63% 却被
  ///   收尾逻辑标记完成 — 已废弃。
  /// - 显式设置最大轮数: 作为硬上限, 跑满仍未达标由收尾逻辑如实标记失败。
  /// - 真实进度查询关闭 (本地进度模式): 无真实进度可判定, 沿用估算轮数。
  Future<void> _fastBrushBurstLoop(VideoSession session) async {
    const autoRounds = 0x3FFFFFFF;
    var maxRounds = _fastBrushMaxRounds;
    if (maxRounds <= 0) {
      if (_realProgressQuery) {
        maxRounds = autoRounds;
      } else {
        final spd = _speed > 0 ? _speed : 1.0;
        maxRounds = max(5, (_completeRatio * spd * 1.5).ceil());
      }
    }

    _emit(
        session,
        PlaybackState.playing,
        maxRounds == autoRounds
            ? '快刷模式: 自动轮数 (刷到真实进度 ≥ ${(_completeRatio * 100).toInt()}% 为止)'
            : '快刷模式: 最大 $maxRounds 轮, 完成阈值 ${(_completeRatio * 100).toInt()}%');

    var completed = false;
    _brushRounds = 0;
    _brushFinalRatio = 0.0;
    _resumePlaytimeMs = 0;

    while (_brushRounds < maxRounds && !_cancelled && !_budgetExhausted) {
      _brushRounds++;
      // 轮前查询服务端进度, 取 playTime 作为续刷起点
      // resumeFromServer=false 时首轮强制从 0 开始 (不读取 playTime 作为起点),
      // 后续轮次始终从 playTime 续刷 (原有行为)
      final preRatio = await _queryProgressRatio(session);
      final resumePtMs = (_brushRounds == 1 && !_resumeFromServer)
          ? 0
          : _resumePlaytimeMs;

      _emit(session, PlaybackState.playing,
          '快刷第 $_brushRounds/$maxRounds 轮 (起点 ${(preRatio * 100).toInt()}%, '
          'resumePlaytime=${resumePtMs}ms'
          '${_brushRounds == 1 && !_resumeFromServer ? ', 从头开始' : ''})');

      await _runCourseSession(
        session,
        enableFocusCheck: !_lessonFocusDone,
        resumePlaytimeMs: resumePtMs,
      );

      if (_cancelled) break;

      // 真实进度查询开启时: 轮询并按阈值提前结束
      // 关闭时: 跳过真实进度查询, 使用本地模拟进度跑完所有轮数
      if (_realProgressQuery) {
        final ratio = await _queryProgressRatio(session);
        _brushFinalRatio = ratio;
        // 用真实进度覆盖本地模拟进度, 让 UI 进度栏显示真实值
        if (ratio > 0 && session.duration > 0) {
          session.playedTime = (ratio * session.duration).round();
          _playedS = session.playedTime;
          _emit(session, PlaybackState.playing,
              '第 $_brushRounds 轮后真实进度 ${(ratio * 100).toInt()}%');
        }
        if (ratio >= _completeRatio && _lessonFocusDone) {
          completed = true;
          _brushTargetMet = true;
          _emit(session, PlaybackState.playing,
              '第 $_brushRounds 轮完成, 真实进度 ${(ratio * 100).toInt()}% ✔');
          break;
        }
      } else {
        _emit(session, PlaybackState.playing,
            '第 $_brushRounds 轮完成 (本地进度模式), 继续重刷...');
      }
    }

    // 互动点已在 _fastBrushLoop 中按 interactiveTimePoint 触发,
    // 并在循环结束时兜底补齐 + _finalizeInteractive, 此处无需再调用。

    if (!completed && !_cancelled) {
      _emit(
          session,
          PlaybackState.playing,
          maxRounds == autoRounds
              ? '自动轮数终止 (预算耗尽或服务端无入账), 最终进度 '
                  '${(_brushFinalRatio * 100).toInt()}%'
              : '已达最大轮数 $maxRounds, 最终进度 '
                  '${(_brushFinalRatio * 100).toInt()}%');
    }
  }

  /// 重刷模式(刷时长, 基于普通模式行为链): 每课固定 [rounds] 轮,
  /// 每轮目标 = 服务器已刷时长 + [extraMinutes] 分钟。
  ///
  /// 对齐 Python brush_course(force_rebrush=True): 滚动增量, 跑满轮数即止, 不按完成阈值提前结束,
  /// 真实上报使服务端 playTime 实际增长。每轮调用 [_runCourseSession] —
  /// 行为链与普通模式一致 (单发心跳, 无 burst 并发), 每轮心跳数按
  /// "媒体时间推进 ≥ 额外时长" 估算封顶 (见 [_normalHeartbeatLoop])。
  Future<void> _rebrushLoop(VideoSession session) async {
    final rounds = _rebrushRounds.clamp(1, 1000);
    final extraMs = _rebrushExtraMinutes.clamp(0, 100000) * 60 * 1000;
    _emit(session, PlaybackState.playing,
        '重刷模式(刷时长): $rounds 轮, 每轮目标 +$_rebrushExtraMinutes 分钟');
    var round = 0;
    while (round < rounds && !_cancelled) {
      round++;
      final startRatio = await _queryProgressRatio(session);
      final startMs = (startRatio * session.duration).round();
      final targetMs = startMs + extraMs;
      _rebrushTargetMs = targetMs;
      _emit(session, PlaybackState.playing,
          '重刷第 $round/$rounds 轮: 起点 ${startMs}ms, 目标 ${targetMs}ms');
      await _runCourseSession(
        session,
        enableFocusCheck: !_lessonFocusDone,
        resumePlaytimeMs: startMs,
      );
      _rebrushTargetMs = 0;
      if (_cancelled) break;
    }
    _emit(session, PlaybackState.playing, '重刷完成: $round/$rounds 轮');
  }

  /// 补偿检测模式: 仅补偿认真度检测点 / 互动点的上报, 不刷进度。
  ///
  /// 复用 [_initialize] 拉取检测点与互动点配置, 直接对每个检测点调用 [_performFocusCheck]、
  /// 对每个互动点调用 [_executeInteractivePoint], 最后 [_finalizeInteractive]。
  /// 不发送进度心跳 / start burst, 故不会推进服务端 playTime。
  Future<void> _compensateLoop(VideoSession session) async {
    _emit(session, PlaybackState.initializing, '补偿检测模式: 仅补偿检测上报, 不刷进度');
    await _initialize(session);
    if (_cancelled) return;

    // 初始化遥测上下文 (否则 _sendCollect 的 uuid/beginTs 等为空, 检测上报可能失败)
    _beginTs = _telemetryRemote.clock.now();
    _uuidPrefix = _genUuidPrefix();
    _uuidSeq = 0;
    _ptiFloat = 0.0;
    _playedS = 0;
    _heartbeatOkCount = 0;
    _pointNum = max(
        1, (session.duration + _heartbeatInterval - 1) ~/ _heartbeatInterval);
    _completedCheckPointCount = 0;
    _interactiveDoneCount = 0;
    _interactiveTotalCount = session.interactiveConfigs.length;

    // 仅启动课程 (record/submit, 不发送进度 burst), 便于服务端接受检测上报
    try {
      await _startPlayback(session, processTimeMs: 0);
    } catch (e) {
      _emit(session, PlaybackState.initializing, '  startPlayback 失败(非致命): $e');
    }

    final checkPoints = _videoCheckPoints.isNotEmpty
        ? _videoCheckPoints
        : _legacyCheckPoints(session.duration);
    final interactiveConfigs = session.interactiveConfigs;
    _emit(session, PlaybackState.focusChecking,
        '补偿检测: 检测点=${checkPoints.length}个, 互动点=${interactiveConfigs.length}个');

    for (var i = 0; i < checkPoints.length && !_cancelled; i++) {
      await _performFocusCheck(session, i + 1, checkPoints[i].toDouble(),
          cpIdx: i + 1, cpTotal: checkPoints.length, checkPointTime: checkPoints[i]);
    }
    _lessonFocusDone = true;

    _interactiveTotalCount = interactiveConfigs.length;
    for (var i = 0; i < interactiveConfigs.length && !_cancelled; i++) {
      await _executeInteractivePoint(
          session, interactiveConfigs[i], i, interactiveConfigs.length);
    }
    if (!_cancelled) await _finalizeInteractive(session);

    _emit(session, PlaybackState.focusChecking, '补偿检测完成');
  }

  // ─── 内部实现 ───

  /// Stage 1: 初始化 - 获取 token / videoInfo / duration / courseId / 互动点 / 黑名单 / 降级配置
  ///
  /// 对应 Python: _execute_init_session + _execute_fetch_video_meta
  /// 对齐 §3'.1.2: 客户端生成 videoCheckPoint 数组
  Future<void> _initialize(VideoSession session) async {
    // 1. 获取 player token (返回纯字符串)
    if (session.playerToken == null || session.playerToken!.isEmpty) {
      try {
        final token = await _playerRemote.getPlayerToken(
          schoolId: session.schoolId,
          lessonId: session.lessonId,
        );
        if (token.isNotEmpty) session.playerToken = token;
        _emit(session, PlaybackState.initializing,
            '  playerToken: ${session.playerToken != null && session.playerToken!.isNotEmpty ? "${session.playerToken!.substring(0, session.playerToken!.length > 12 ? 12 : session.playerToken!.length)}..." : "空"}');
      } catch (e) {
        _emit(session, PlaybackState.initializing,
            '  getPlayerToken 失败(非致命): $e');
      }
    }

    // 2. 获取 videoInfo (复用: 时长 + 互动点)
    Map<String, dynamic>? evData;
    if (session.duration == 0 ||
        session.interactiveConfigs.isEmpty &&
            session.playerToken != null &&
            session.playerToken!.isNotEmpty) {
      try {
        final videoInfo = await _playerRemote.getExternalVideoInfo(
          lessonId: session.lessonId,
          videoToken: session.playerToken ?? '',
        );
        evData = videoInfo;
        _emit(session, PlaybackState.initializing,
            '  getExternalVideoInfo: ok');
      } catch (e) {
        _emit(session, PlaybackState.initializing,
            '  getExternalVideoInfo 失败(非致命): $e');
      }
    }

    // 3. 提取互动点配置 (对应 Python _extract_interactive_configs)
    if (session.interactiveConfigs.isEmpty && evData != null) {
      final info = evData['interactiveInfo'] as Map<String, dynamic>?;
      final list = (info?['interactiveConfigList'] as List<dynamic>?) ?? [];
      final configs = <InteractiveConfig>[];
      for (final c in list) {
        if (c is Map<String, dynamic> && c['id'] != null) {
          configs.add(InteractiveConfig(
            id: c['id'].toString(),
            timePoint: _parseIntField(c['timePoint']),
          ));
        }
      }
      session.interactiveConfigs = configs;
      _isInteractiveVideo = configs.isNotEmpty;
      if (configs.isNotEmpty) {
        _emit(session, PlaybackState.initializing,
            '  互动视频: ${configs.length} 个互动点, '
            '时间点=${configs.map((c) => "${c.timePoint}ms").join(",")}');
      }
    }

    // 4. 获取视频时长 (多源优先级, 对应 Python _get_video_duration)
    if (session.duration == 0) {
      session.duration = await _resolveDuration(session, evData);
    }
    // 兜底默认 600s
    if (session.duration == 0) {
      session.duration = 600;
      _emit(session, PlaybackState.initializing, '  使用默认时长 600s');
    }
    _emit(session, PlaybackState.initializing,
        '  视频时长: ${session.duration}s (${(session.duration / 60).toStringAsFixed(1)}min)');

    // 5. 获取 courseId (getLessonDetailV2.data.courseId)
    //    同时提取 interactiveVideo 字段用于 addVideoss.type 映射
    if ((session.courseId == null || session.courseId!.isEmpty) &&
        session.homeworkId.isNotEmpty &&
        session.schoolId.isNotEmpty) {
      try {
        final detail = await _playerRemote.getLessonDetail(
          schoolId: session.schoolId,
          homeworkId: session.homeworkId,
          lessonId: session.lessonId,
        );
        final cid = detail['courseId']?.toString();
        if (cid != null && cid.isNotEmpty) session.courseId = cid;
        // 提取 interactiveVideo 标记
        final iv = detail['interactiveVideo'];
        if (iv is bool) _isInteractiveVideo = iv;
        _emit(session, PlaybackState.initializing,
            '  getLessonDetailV2: courseId=${session.courseId ?? "(空)"}, '
            'interactiveVideo=$_isInteractiveVideo');
      } catch (e) {
        _emit(session, PlaybackState.initializing,
            '  getLessonDetailV2 失败(非致命): $e');
      }
    }

    // 6. 获取认真度检测降级配置 (对齐浏览器播放页进入时调用)
    //    周培优无 homeworkId, 但该接口仅需 schoolId, 不受影响
    if (session.schoolId.isNotEmpty) {
      try {
        final cfg = await _playerRemote.getSeriousCheckDownGradeConfig(
          schoolId: session.schoolId,
          videoType: 1,
        );
        _seriousCheckConfig = SeriousCheckConfig.fromJson(cfg);
        _emit(
          session,
          PlaybackState.initializing,
          '  认真度检测: ${_seriousCheckConfig.isDowngrade ? "已降级" : "正常"} '
              '(level=${_seriousCheckConfig.level}, needLog=${_seriousCheckConfig.needLog})'
              '${_seriousCheckConfig.isDowngrade ? " - ${_seriousCheckConfig.tips}" : ""}',
        );
      } catch (e) {
        _emit(session, PlaybackState.initializing,
            '  getSeriousCheckDownGradeConfig 失败(非致命): $e');
      }
    }

    // 7. 查询黑名单状态 (对齐 §3'.7.1)
    //    isBlacklisted=true → 走滑块型 (ek 组件, ecaptcha)
    //    isBlacklisted=false → 走确认型 (ev 组件, 仅点击"我知道了")
    try {
      _isBlacklisted = await _playerRemote.getVideodp();
      _emit(session, PlaybackState.initializing,
          '  黑名单状态(getVideodp): ${_isBlacklisted ? "在黑名单 → 滑块型检测" : "普通用户 → 确认型检测"}',
          );
    } catch (e) {
      _emit(session, PlaybackState.initializing,
          '  getVideodp 失败(非致命, 默认普通用户): $e');
    }

    // 8. 客户端生成 videoCheckPoint 数组 (对齐 §3'.1.2)
    _videoCheckPoints = _generateVideoCheckPoints(
      session.duration,
      session.interactiveConfigs,
    );
    if (_videoCheckPoints.isNotEmpty) {
      _emit(session, PlaybackState.initializing,
          '  客户端检测点(videoCheckPoint): ${_videoCheckPoints.join(", ")}s '
          '(${_videoCheckPoints.length} 个)');
    } else {
      _emit(session, PlaybackState.initializing,
          '  客户端检测点(videoCheckPoint): 无 (视频时长或互动配置不满足生成条件)');
    }
  }

  /// 客户端生成 videoCheckPoint 检测点数组 (对齐 §3'.1.2)
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
    List<InteractiveConfig> interactiveConfigs,
  ) {
    final z = durationSeconds.toDouble();
    if (z <= 0) return const [];

    // 有互动题
    if (interactiveConfigs.isNotEmpty) {
      final t = interactiveConfigs.length;
      if (t >= 3 || z <= 480) return const [];
      final lastTpMs = interactiveConfigs.last.timePoint;
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

  /// 在 [start, end] 区间生成 count 个时间点, 最小间隔 minInterval 秒
  ///
  /// 对齐浏览器 ea.MH 工具函数: 等间距分布 + 随机扰动 (但保证最小间隔)。
  List<int> _mhRange(int start, int end, int count, int minInterval) {
    if (count <= 0 || end <= start) return const [];
    final range = end - start;
    if (range < count * minInterval) {
      // 区间不够, 退化等分
      final step = range ~/ (count + 1);
      return List.generate(count, (i) => start + step * (i + 1));
    }
    // 均匀分布 + 轻微随机扰动
    final step = range ~/ (count + 1);
    final result = <int>[];
    for (var i = 0; i < count; i++) {
      final base = start + step * (i + 1);
      final jitter = _random.nextInt(min(60, step ~/ 4 + 1)) - (step ~/ 8);
      result.add((base + jitter).clamp(start, end));
    }
    result.sort();
    return result;
  }

  /// 多源解析视频时长 (对应 Python _get_video_duration)
  ///
  /// 优先级: course.duration → lessonTime → videoPlayTime → evData.duration → 600
  Future<int> _resolveDuration(
    VideoSession session,
    Map<String, dynamic>? evData,
  ) async {
    // P1: evData.duration (来自 getExternalVideoInfo)
    if (evData != null) {
      var d = _parseIntField(evData['duration']);
      if (d > 0) return d;
      // 尝试 videoList[0].duration
      final videoList = evData['videoList'] as List<dynamic>?;
      if (videoList != null && videoList.isNotEmpty) {
        final first = videoList.first;
        if (first is Map<String, dynamic>) {
          d = _parseIntField(first['duration']);
          if (d > 0) return d;
        }
      }
    }

    // P2: getUserHomeworkLessonTaskInfo.lessonTime (ms → s)
    if (session.homeworkId.isNotEmpty && session.schoolId.isNotEmpty) {
      try {
        final ti = await _playerRemote.getLessonTaskInfo(
          homeworkId: session.homeworkId,
          lessonId: session.lessonId,
          contentType: session.contentType,
          schoolId: session.schoolId,
        );
        final lessonTimeMs = _parseIntField(ti['lessonTime']);
        if (lessonTimeMs > 0) return lessonTimeMs ~/ 1000;
      } catch (_) {}
    }

    // P3: getLessonDetailV2.videoPlayTime (浮点秒)
    if (session.homeworkId.isNotEmpty && session.schoolId.isNotEmpty) {
      try {
        final ld = await _playerRemote.getLessonDetail(
          schoolId: session.schoolId,
          homeworkId: session.homeworkId,
          lessonId: session.lessonId,
        );
        final vpt = ld['videoPlayTime'];
        if (vpt != null) {
          final d = double.tryParse(vpt.toString()) ?? 0.0;
          if (d > 0) return d.toInt();
        }
      } catch (_) {}
    }

    return 0;
  }

  int _parseIntField(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  /// Stage 2: record/submit (开始观看)
  ///
  /// 对应 Python: _execute_record_submit_start
  /// [processTimeMs] 续刷时携带已完成进度, 首刷/正常为 0
  Future<void> _startPlayback(
    VideoSession session, {
    int processTimeMs = 0,
  }) async {
    try {
      await _playerRemote
          .submitRecord(
            courseId: session.courseId ?? session.lessonId,
            lessonId: session.lessonId,
            processTime: max(0, processTimeMs),
            finished: 0,
          )
          .timeout(const Duration(seconds: 10));
      _emit(session, PlaybackState.starting,
          '  record/submit ok (processTime=${processTimeMs}ms, courseId=${session.courseId ?? session.lessonId})');
    } catch (e) {
      // 已完成课程返回 7770505 或网络超时均忽略
      _emit(session, PlaybackState.starting,
          '  record/submit 失败(非致命): $e');
    }
  }

  /// Stage 3: 起始 burst (对应 Python `_execute_collect_burst_start`)
  ///
  /// act=2 (会话状态, stay=6) → act=1 (play) → act=3 (初始暂停) → act=2 (恢复, pti=1)
  Future<void> _sendStartBurst(VideoSession session) async {
    _emit(session, PlaybackState.starting, '  起始 burst (act=2,1,3,2):');
    final r1 = await _sendCollect(session, action: 2, stayMs: 6, pti: 0);
    _logCollectResult(session, r1, prefix: '    [act=2 初始] ');
    if (_cancelled) return;
    final r2 = await _sendCollect(session, action: 1, stayMs: 0, pti: 0);
    _logCollectResult(session, r2, prefix: '    [act=1 START] ');
    if (_cancelled) return;
    final r3 = await _sendCollect(session, action: 3, stayMs: 0, pti: 0);
    _logCollectResult(session, r3, prefix: '    [act=3 PAUSED] ');
    if (_cancelled) return;
    final r4 = await _sendCollect(session, action: 2, stayMs: 0, pti: 1);
    _logCollectResult(session, r4, prefix: '    [act=2 恢复] ');
    _lastPti = 1;
    _ptiFloat = 1.0;
  }

  /// Stage 4 正常模式心跳循环 (对应 Python `_execute_heartbeat_loop`)
  ///
  /// 墙钟心跳周期固定 [_heartbeatInterval] 秒 (不随倍速缩短);
  /// stay_time = interval*1000 (墙钟ms, 固定);
  /// media_time = interval*speed*1000 (媒体ms);
  /// point_time_id 每次心跳 += speed (浮点累积后取整)。
  ///
  /// 认真度检测点: 优先使用客户端生成的 videoCheckPoint 数组,
  /// 兜底使用按时长 0/1/2/3 个的简化算法 (向后兼容)。
  Future<void> _normalHeartbeatLoop(
    VideoSession session, {
    bool enableFocusCheck = true,
  }) async {
    final interval = _heartbeatInterval;
    final speed = _speed;
    var fullHb = speed >= 1
        ? max(1, (_pointNum + speed.toInt() - 1) ~/ speed.toInt())
        : _pointNum;

    // 重刷模式(刷时长): 本轮心跳数按"媒体时间推进 ≥ 额外时长"估算封顶,
    // 即每轮恰好上报约 rebrushExtraMinutes 分钟的媒体时长;
    // 服务端真实进度达本轮目标 (_rebrushTargetMs) 时由下方轮询提前结束。
    if (_rebrushTargetMs > 0) {
      final perHbMs = (interval * speed * 1000).toInt();
      if (perHbMs > 0) {
        final roundHb =
            max(1, (_rebrushExtraMinutes * 60 * 1000 + perHbMs - 1) ~/ perHbMs);
        fullHb = min(fullHb, roundHb);
      }
    }

    // 检测点: 优先使用客户端生成的 videoCheckPoint, 否则用简化算法
    final checkPoints = _videoCheckPoints.isNotEmpty
        ? _videoCheckPoints
        : _legacyCheckPoints(session.duration);
    var cpIdx = 0;
    // 互动点: 按 interactiveTimePoint (秒) 触发
    final interactiveConfigs = session.interactiveConfigs;
    var ipIdx = 0;
    var lastProgressPersist = 0;
    final playprogEvery =
        max(1, AppConstants.progressPersistInterval ~/ interval);
    // 真实进度轮询时间戳 (仅 _realProgressQuery=true 时使用)
    var lastProgressQueryTs = DateTime.now().millisecondsSinceEpoch;

    _emit(session, PlaybackState.playing,
        '心跳循环开始: $fullHb 轮 × ${interval}s, 检测点=${checkPoints.length}个, speed=${speed}x'
        '${_realProgressQuery ? ", 真实进度查询" : ", 本地进度模式"}');

    for (var h = 1; h <= fullHb && !_cancelled; h++) {
      _emit(session, PlaybackState.playing,
          '心跳 $h/$fullHb: 等待 ${interval}s...');
      await Future.delayed(Duration(seconds: interval));
      if (_cancelled) break;

      _ptiFloat += speed;
      final pti = _ptiFloat.toInt();
      final playedS = min(pti * interval, session.duration);
      final stayMs = interval * 1000;
      final mediaMs = (interval * speed * 1000).toInt();

      final r = await _sendCollect(session,
          action: 2, stayMs: stayMs, pti: pti, mediaMs: mediaMs);
      _logCollectResult(session, r,
          prefix: '    [hb#$h act=2] ',
          extra: 'pti=$pti, played=${playedS}s/${session.duration}s, '
              'stay=${stayMs}ms, media=${mediaMs}ms');
      _lastPti = pti;
      _heartbeatOkCount++;

      session.playedTime = playedS;
      _playedS = playedS;

      // 检测点到达触发 (对齐 §3'.1.2: R.includes(N) || R.includes(N-1))
      while (cpIdx < checkPoints.length && !_cancelled) {
        final cp = checkPoints[cpIdx];
        if (cp > playedS && cp > playedS + 1) break;
        if (cp <= playedS || cp == playedS + 1) {
          cpIdx++;
          await _performFocusCheck(session, pti, playedS.toDouble(),
              cpIdx: cpIdx, cpTotal: checkPoints.length, checkPointTime: cp);
          if (_cancelled) break;
        } else {
          break;
        }
      }
      if (_cancelled) break;

      // 互动点到达触发 (按 interactiveTimePoint, 单位: 毫秒 → 秒)
      while (ipIdx < interactiveConfigs.length && !_cancelled) {
        final cfg = interactiveConfigs[ipIdx];
        final tpSec = cfg.timePoint ~/ 1000;
        if (tpSec > playedS + 1) break;
        // 进度到达或超过互动时间点 → 触发
        ipIdx++;
        _interactiveDoneCount = ipIdx;
        await _executeInteractivePoint(
            session, cfg, ipIdx - 1, interactiveConfigs.length);
        if (_cancelled) break;
      }
      if (_cancelled) break;

      // 周期性进度持久化 (按播放时长)
      if (playedS - lastProgressPersist >=
          AppConstants.progressPersistInterval) {
        await _persistProgress(session);
        lastProgressPersist = playedS;
      }
      // 周期性进度持久化 (事件触发的补充保险)
      if (h % playprogEvery == 0) {
        await _persistProgress(session);
      }

      // 真实进度轮询: 达阈值提前结束 (仅 _realProgressQuery=true 时)
      if (_realProgressQuery) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastProgressQueryTs >= _progressPollInterval * 1000) {
          lastProgressQueryTs = now;
          try {
            final polled = await _queryProgressRatio(session);
            // 用真实进度覆盖本地模拟进度, 让 UI 进度栏和日志显示真实值
            // (避免本地 playedS 远小于真实进度时, UI 进度栏长时间停滞)
            if (polled > 0 && session.duration > 0) {
              session.playedTime = (polled * session.duration).round();
              _playedS = session.playedTime;
            }
            // 重刷模式(刷时长): 本轮目标为固定 playTime, 达标即结束本轮 (不按完成阈值)
            if (_rebrushTargetMs > 0) {
              _emit(session, PlaybackState.playing,
                  '    [轮询] 真实进度 ${(polled * 100).toInt()}% '
                  '(本轮目标 ${_rebrushTargetMs}ms, 检测点 $cpIdx/${checkPoints.length})');
              // playedTime 为秒, 目标为毫秒, 统一到毫秒比较
              if (session.playedTime * 1000 >= _rebrushTargetMs) {
                _brushFinalRatio = polled;
                _emit(session, PlaybackState.playing,
                    '    本轮已达目标时长, 结束本轮 ✔');
                break;
              }
            } else {
              _emit(session, PlaybackState.playing,
                  '    [轮询] 真实进度 ${(polled * 100).toInt()}% '
                  '(阈值 ${(_completeRatio * 100).toInt()}%, 检测点 $cpIdx/${checkPoints.length})');
              // 真实进度达阈值即提前结束, 未触发的检测点/互动点由循环后兜底补齐
              if (polled >= _completeRatio) {
                // 记录最终进度, 让 _sendRemainderHeartbeat 跳过余量等待
                // (否则提前结束反而要真实等待 duration−pti×interval 的墙钟时长)
                _brushFinalRatio = polled;
                _emit(session, PlaybackState.playing,
                    '    真实进度已达阈值, 提前结束 ✔');
                break;
              }
            }
          } catch (_) {}
        }
      }
    }

    // 兜底补齐未触发的检测点
    while (enableFocusCheck && !_cancelled && cpIdx < checkPoints.length) {
      cpIdx++;
      final cp = checkPoints[cpIdx - 1];
      await _performFocusCheck(session, _lastPti, _playedS.toDouble(),
          cpIdx: cpIdx, cpTotal: checkPoints.length, checkPointTime: cp);
    }

    if (cpIdx >= checkPoints.length && checkPoints.isNotEmpty) {
      _lessonFocusDone = true;
    } else if (checkPoints.isEmpty) {
      _lessonFocusDone = true;
    }

    // 兜底补齐未触发的互动点
    while (!_cancelled && ipIdx < interactiveConfigs.length) {
      final cfg = interactiveConfigs[ipIdx];
      ipIdx++;
      _interactiveDoneCount = ipIdx;
      await _executeInteractivePoint(
          session, cfg, ipIdx - 1, interactiveConfigs.length);
    }
    if (ipIdx >= interactiveConfigs.length && !_lessonInteractiveDone) {
      await _finalizeInteractive(session);
    }
  }

  /// Stage 4 快刷模式心跳循环 (普通模式实现 + 静态 burst 多线程并发)
  ///
  /// 与 [_normalHeartbeatLoop] 结构完全一致 (真实等待 + 检测点 + 互动点 +
  /// 进度持久化 + 真实进度轮询), 唯一区别: 每次心跳发送 [_fastBrushThreads]
  /// 个 collect 包并发 (静态 burst), 对同一课程同一位置多次上报。
  ///
  /// 多轮重刷由 [_fastBrushBurstLoop] 驱动。
  Future<void> _fastBrushLoop(
    VideoSession session, {
    bool enableFocusCheck = true,
  }) async {
    final baseInterval = _heartbeatInterval;
    var interval = baseInterval;
    // 预算感知节流 (2026-08-26 实测校准):
    // 服务端按账号维护滚动入账预算, 连续高并发上报后每请求入账率波动
    // (单轮 18 并发入账 +80~240s, 约 4~12/18 入账)。入账延迟约 30s,
    // 故 progressPollInterval=35s (≥延迟) 避免误判无入账。轮询增量过小
    // 时拉长心跳间隔给预算恢复; 连续 4 轮无入账则提示冷却/换账号。
    var lowYieldStreak = 0;
    var lastPolledRatio = 0.0;
    final speed = _speed;
    // 快刷2: 每轮少量爆发(3心跳)多轮重刷, 避免密集爆发耗尽账号预算
    // (实测 11心跳/轮×5轮=990爆发, 入账率仅13%≈2.3/18; 改3心跳/轮多轮,
    //  爆发密度降为1/3.7, 入账率回升至~33%≈6/18, 对齐 Python test_speedrun
    //  的"少量爆发+长间隔多轮"模式。检测点在多轮重刷中补齐触发)
    final fullHb = _fastBrush2
        ? 3
        : (speed >= 1
            ? max(1, (_pointNum + speed.toInt() - 1) ~/ speed.toInt())
            : _pointNum);
    // 并发请求数 = 用户配置的快刷并发线程数 (允许 1), 与每请求事件数完全解耦。
    // 修复: 原先 _fastBrushEventsPerRequest>0 时错误地覆盖 threads, 导致并发线程数
    // 设置无效 (含设置为 1 时被顶掉)。
    final threads = _fastBrushThreads.clamp(1, 200);
    // 每请求事件数 (EventPackage 长度, 对齐 Python `_resolve_multi`):
    //   fastBrushEventsPerRequest > 0 → 用户显式指定
    //   = 0 (自动)                     → 服务端 getPlayerGlobalConf.maxBatchSize
    final multiEvents = (_fastBrushEventsPerRequest > 0
            ? _fastBrushEventsPerRequest
            : _maxBatchSize)
        .clamp(1, 200);
    // 服务端限流退避: 连续失败次数 → 指数退避
    var failStreak = 0;

    // 检测点: 优先使用客户端生成的 videoCheckPoint, 否则用简化算法
    final checkPoints = _videoCheckPoints.isNotEmpty
        ? _videoCheckPoints
        : _legacyCheckPoints(session.duration);
    var cpIdx = enableFocusCheck ? 0 : checkPoints.length;
    // 互动点: 按 interactiveTimePoint (秒) 触发
    final interactiveConfigs = session.interactiveConfigs;
    var ipIdx = 0;
    var lastProgressPersist = 0;
    final playprogEvery =
        max(1, AppConstants.progressPersistInterval ~/ baseInterval);
    // 真实进度轮询时间戳 (仅 _realProgressQuery=true 时使用)
    var lastProgressQueryTs = DateTime.now().millisecondsSinceEpoch;

    // 快刷模式2: 每轮铸造 N 个新会话 (getPlayerGlobalConf 每次调用返回新
    // sessionId+secret, 免费无频控), 每个会话自带独立 ~45s 初始限速预算;
    // 旧会话预算跨轮耗尽后由新会话重置预算窗口 (对齐 probe11 每相重新 mint)。
    var minted = const <_SessionConf>[];
    if (_fastBrush2) {
      minted = await _mintSessions(session);
      if (_cancelled) return;
    }

    _emit(session, PlaybackState.playing,
        '快刷心跳循环 (${_fastBrush2 ? "多session×${minted.length}" : "普通+burst"}): $fullHb 轮 × ${interval}s, '
        '并发 $threads 线程/心跳, 每请求 $multiEvents 事件, '
        '检测点=${checkPoints.length}个, speed=${speed}x'
        '${_realProgressQuery ? ", 真实进度查询" : ", 本地进度模式"}'
        '${_fastBrush2 ? ", 预算感知节流" : ""}');

    for (var h = 1; h <= fullHb && !_cancelled; h++) {
      _emit(session, PlaybackState.playing,
          '心跳 $h/$fullHb: 等待 ${interval}s...');
      await Future.delayed(Duration(seconds: interval));
      if (_cancelled) break;

      _ptiFloat += speed;
      final pti = _ptiFloat.toInt();
      final playedS = min(pti * interval, session.duration);
      final stayMs = _fastBrushStayTime > 0 ? _fastBrushStayTime : interval * 1000;
      // 修复: 原先 (stayMs * speed / 1000) 把毫秒误除 1000 变成秒量级 (如 20),
      // 导致 media_time 远小于 stay_time, 服务端按媒体时长累计时几乎无增长。
      // media_time 与 stay_time 同单位 (毫秒), 倍速下 = stayMs * speed
      // (对齐 Python burst_report: media_time = stay_time + j*stay_time, speed 独立字段)。
      final mediaMs = (stayMs * speed).toInt();

      // 静态 burst: threads 个请求并发, 每个请求打包 multiEvents 个事件
      // (对齐 Python `_collect_burst` + `_resolve_multi`:
      //  线程数 = BURST_THREADS, 每请求事件数 = EVENTS_PER_REQUEST / maxBatchSize)
      //
      // 快刷模式2 (_fastBrush2): 多 session 预算乘法, 请求轮流分发到
      // 铸造会话池 + bfe/clog/dlog 三端点 (限速预算按 session 独立核算)
      List<CollectResult> results;
      int okEvents;
      if (_fastBrush2) {
        // V8 多 session 预算乘法 (probe11/probe11c 坐实, 2026-09-25):
        // 限速预算键 = x-bfe-session-id (客户端可 mint), 每个 session 独立
        // 核算信用, 与端点数/请求数无关。本轮爆发:
        //   总请求 = 会话数 × 每会话请求数, 请求 i → 端点 hosts[i%3],
        //   会话 = minted[i~/per] (每 per 个连续请求落在同一会话)。
        // 单请求声明 credit = stayMs×speed; 每会话单轮信用压在 ~40s 初始
        // 预算内 (probe11c: N=8, 80 请求 stay=2000 speed=2, 3.7s 爆发净增
        // +192s, 零硬拒绝; 超预算部分被静默软钳制不入账, 故宁少勿多)。
        // 必须 Future.wait 真并发: 全部请求需落在同一预算窗口内到达。
        final creditPerReq = max(1, (stayMs * speed).toInt());
        final per = (_ms2SessionBudgetMs ~/ creditPerReq).clamp(1, threads);
        final total = minted.length * per;
        results = await Future.wait([
          for (var i = 0; i < total; i++)
            _sendCollectToHost(session,
                host: _ms2Hosts[i % _ms2Hosts.length],
                conf: minted[i ~/ per],
                action: 2,
                stayMs: stayMs,
                pti: pti,
                mediaMs: mediaMs),
        ]);
        okEvents = 0;
        for (var i = 0; i < results.length; i++) {
          final r = results[i];
          _logCollectResult(session, r,
              prefix:
                  '    [ms2#$h s${(i ~/ per) + 1}/${minted.length} ${r.host}] ',
              extra: 'pti=$pti, played=${playedS}s/${session.duration}s, '
                  'stay=${stayMs}ms, media=${mediaMs}ms, '
                  'credit=${creditPerReq}ms/req');
          if (r.isOk) {
            _heartbeatOkCount++;
            okEvents++;
          }
        }
      } else {
        results = await Future.wait([
          for (var t = 0; t < threads; t++)
            _sendCollect(session,
                action: 2,
                stayMs: stayMs,
                pti: pti,
                mediaMs: mediaMs,
                multiEvents: multiEvents),
        ]);
        okEvents = 0;
        for (var t = 0; t < results.length; t++) {
          _logCollectResult(session, results[t],
              prefix: '    [fb#$h t${t + 1} act=2] ',
              extra: 'pti=$pti, played=${playedS}s/${session.duration}s, '
                  'stay=${stayMs}ms, media=${mediaMs}ms, '
                  'events=${multiEvents}/req');
          if (results[t].isOk) {
            _heartbeatOkCount++;
            okEvents += multiEvents;
          }
        }
      }
      // 限流退避: 本轮全部请求失败则指数退避, 避免雪崩
      if (okEvents == 0 && results.isNotEmpty) {
        failStreak++;
        final backoff =
            _fastBrushWafBackoff * (1 << (failStreak - 1).clamp(0, 6));
        _emit(session, PlaybackState.playing,
            '    [fb#$h] 全部失败, 退避 $backoff ms (连续 $failStreak 次)');
        await Future.delayed(Duration(milliseconds: backoff));
      } else {
        failStreak = 0;
      }
      _lastPti = pti;

      session.playedTime = playedS;
      _playedS = playedS;

      // 检测点到达触发 (对齐 §3'.1.2: R.includes(N) || R.includes(N-1))
      while (cpIdx < checkPoints.length && !_cancelled) {
        final cp = checkPoints[cpIdx];
        if (cp > playedS && cp > playedS + 1) break;
        if (cp <= playedS || cp == playedS + 1) {
          cpIdx++;
          await _performFocusCheck(session, pti, playedS.toDouble(),
              cpIdx: cpIdx, cpTotal: checkPoints.length, checkPointTime: cp);
          if (_cancelled) break;
        } else {
          break;
        }
      }
      if (_cancelled) break;

      // 所有检测点已触发 → 立即标记认真度检测完成
      // (修复: 原先 _lessonFocusDone 仅在循环结束后设置, 导致真实进度查询
      //  达阈值时无法提前结束本轮)
      if (cpIdx >= checkPoints.length && !_lessonFocusDone) {
        _lessonFocusDone = true;
      }

      // 互动点到达触发 (按 interactiveTimePoint, 单位: 毫秒 → 秒)
      while (ipIdx < interactiveConfigs.length && !_cancelled) {
        final cfg = interactiveConfigs[ipIdx];
        final tpSec = cfg.timePoint ~/ 1000;
        if (tpSec > playedS + 1) break;
        ipIdx++;
        _interactiveDoneCount = ipIdx;
        await _executeInteractivePoint(
            session, cfg, ipIdx - 1, interactiveConfigs.length);
        if (_cancelled) break;
      }
      if (_cancelled) break;

      // 周期性进度持久化 (按播放时长)
      if (playedS - lastProgressPersist >=
          AppConstants.progressPersistInterval) {
        await _persistProgress(session);
        lastProgressPersist = playedS;
      }
      // 周期性进度持久化 (事件触发的补充保险)
      if (h % playprogEvery == 0) {
        await _persistProgress(session);
      }

      // 真实进度轮询: 达阈值提前结束 (仅 _realProgressQuery=true 时)
      if (_realProgressQuery) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastProgressQueryTs >= _progressPollInterval * 1000) {
          lastProgressQueryTs = now;
          try {
            final polled = await _queryProgressRatio(session);
            _brushFinalRatio = polled;
            // 用真实进度覆盖本地模拟进度, 让 UI 进度栏和日志显示真实值
            if (polled > 0 && session.duration > 0) {
              session.playedTime = (polled * session.duration).round();
              _playedS = session.playedTime;
            }
            _emit(session, PlaybackState.playing,
                '    [轮询] 真实进度 ${(polled * 100).toInt()}% '
                '(阈值 ${(_completeRatio * 100).toInt()}%, 检测点 $cpIdx/${checkPoints.length})');
            // 预算感知节流 (2026-08-26 修复: 不再拉长间隔):
            // 入账延迟约 30s (服务端异步聚合), 35s 轮询时最近 1~2 轮入账可能
            // 尚未到达, 增量 < 1% 不一定是预算耗尽。实测固定节奏爆发(12s)
            // 6 轮入账 +720s, 拉长间隔反而让爆发变慢、加速不明显(用户反馈
            // "只有第一次突发跳到15%, 之后逐渐慢下来")。
            // 修复: 增量阈值降至 0.3% (容忍延迟入账波动), 不拉长 interval
            // (保持固定节奏), 仅连续 6 轮(210s)完全无入账才判定预算耗尽退出。
            if (lastPolledRatio > 0 && _fastBrush2) {
              final gain = polled - lastPolledRatio;
              if (gain < 0.003) {
                lowYieldStreak++;
                // 不拉长间隔: 固定节奏爆发入账率最优, 拉长只会越来越慢
                _emit(session, PlaybackState.playing,
                    '    [节流] 轮询增量 ${(gain * 100).toStringAsFixed(2)}% '
                    '(连续 $lowYieldStreak 次 <0.3%), 保持 ${interval}s 固定节奏');
                if (lowYieldStreak >= 6) {
                  _budgetExhausted = true;
                  _brushFinalRatio = polled;
                  _emit(session, PlaybackState.playing,
                      '    ⚠️ 连续 6 轮(210s)无入账, 疑似账号预算耗尽, 提前结束本课时 '
                      '(建议冷却或切换账号)');
                  break;
                }
              } else {
                lowYieldStreak = 0;
              }
            }
            lastPolledRatio = polled;
            // 真实进度达阈值即提前结束, 未触发的检测点/互动点由循环后兜底补齐
            if (polled >= _completeRatio) {
              _emit(session, PlaybackState.playing,
                  '    真实进度已达阈值, 提前结束 ✔');
              break;
            }
          } catch (_) {}
        }
      }
    }

    // 兜底补齐未触发的检测点
    while (enableFocusCheck && !_cancelled && cpIdx < checkPoints.length) {
      cpIdx++;
      final cp = checkPoints[cpIdx - 1];
      await _performFocusCheck(session, _lastPti, _playedS.toDouble(),
          cpIdx: cpIdx, cpTotal: checkPoints.length, checkPointTime: cp);
    }

    if (cpIdx >= checkPoints.length && checkPoints.isNotEmpty) {
      _lessonFocusDone = true;
    } else if (checkPoints.isEmpty) {
      _lessonFocusDone = true;
    }

    // 兜底补齐未触发的互动点
    while (!_cancelled && ipIdx < interactiveConfigs.length) {
      final cfg = interactiveConfigs[ipIdx];
      ipIdx++;
      _interactiveDoneCount = ipIdx;
      await _executeInteractivePoint(
          session, cfg, ipIdx - 1, interactiveConfigs.length);
    }
    if (ipIdx >= interactiveConfigs.length && !_lessonInteractiveDone) {
      await _finalizeInteractive(session);
    }
  }

  /// 旧版检测点算法 (向后兼容, 仅在 videoCheckPoint 生成失败时使用)
  ///
  /// 对应 Python: _checkpoint_count (docs/FOCUS_CHECK_API.md §5.1)
  ///   Z <= 180s          → 0 个
  ///   M = Z-120 in (0, 360]    → 1 个
  ///   M in (360, 720]          → 2 个
  ///   M > 720                  → 3 个
  ///
  /// 返回时间点列表 (秒), 均匀分布在 [121, 0.8*Z] 区间。
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

  /// 认真度检测点完整时序 (对应 Python `_execute_focus_checkpoint`)
  ///
  /// 对齐浏览器 ek/ev 组件 (webpack 模块 10217) 的认真度检测真实时序:
  ///   act=3(pause) → addVideoss(0, 无token, 首报) + **主动**解算滑块 →
  ///   ~click_delay 用户点击 → addVideoss(2, captchaToken) → act=2(恢复) → playbackProgress
  ///
  /// 降级模式 ([SeriousCheckConfig.isDowngrade]): 仅输出日志到进度流, 不执行
  /// act=3 暂停 / 滑块 / addVideoss 打断 (对齐文档 §2.0.5: level>0 为降级)。
  ///
  /// 正常模式 (level==0): 执行完整流程, 黑名单用户走滑块验证, 非黑名单走确认型。
  ///
  /// 黑名单状态 ([isBlacklisted]):
  ///   true  → 主动解算滑块 (ek 组件, ecaptcha)
  ///   false → 仅确认 (ev 组件, 不解算滑块, 直接二次上报 seriousCheckResult=2)
  ///
  /// [checkPointTime] 客户端生成的检测点时间 (秒), 用于日志显示
  Future<void> _performFocusCheck(
    VideoSession session,
    int pti,
    double playedS, {
    int cpIdx = 1,
    int cpTotal = 1,
    int? checkPointTime,
  }) async {
    // 更新已完成检测点计数 (用于 UI 显示 "已完成/全部检测点")
    _completedCheckPointCount = cpIdx;

    final cpTimeStr = checkPointTime != null ? '${checkPointTime}s' : '?';
    _emit(session, PlaybackState.focusChecking,
        '认真度检测 $cpIdx/$cpTotal (检测点=$cpTimeStr, 当前=${playedS.toInt()}s, '
        '黑名单=${_isBlacklisted ? "是→滑块" : "否→确认"})');

    // 降级模式: 仅记录日志, 不执行任何打断/滑块操作
    if (_seriousCheckConfig.isDowngrade) {
      _emit(session, PlaybackState.playing,
          '  认真度检测 $cpIdx/$cpTotal 已降级 (仅日志): ${_seriousCheckConfig.tips}');
      return;
    }

    // 解析 interactivePointId (互动视频检测点使用真实 ID, 普通视频为 null)
    // 对齐 §3'.6: interactivePointId = interactiveVideo ? detail.id : null
    final interactivePointId = await _resolveFocusInteractivePointId(session);

    // 计算 addVideoss.type (对齐 §3'.6):
    //   type = interactiveVideo ? 3 : (contentType==1 ? 1 : 2)
    final addVideoType = _isInteractiveVideo
        ? 3
        : (session.contentType == 1 ? 1 : 2);

    _emit(session, PlaybackState.focusChecking,
        '  addVideoss 参数: type=$addVideoType '
        '(${_isInteractiveVideo ? "互动视频" : session.contentType == 1 ? "普通视频" : "其他非互动"}), '
        'interactivePointId=${interactivePointId ?? "null"}');

    // act=3 检测点暂停
    final r3 = await _sendCollect(session, action: 3, stayMs: 0, pti: pti);
    _logCollectResult(session, r3, prefix: '    [act=3 检测点暂停] ');

    // —— 首报: 非黑名单→addVideoss / 黑名单→addVideocss (seriousCheckResult=0, 无 token) ——
    final apiName0 = _isBlacklisted ? 'addVideocss' : 'addVideoss';
    try {
      await _sendVideoCheck(
        session,
        seriousCheckResult: 0,
        type: addVideoType,
        interactivePointId: interactivePointId,
      );
      _emit(session, PlaybackState.focusChecking,
          '  $apiName0(0) 首报 ok (type=$addVideoType, ipId=$interactivePointId)');
    } catch (e) {
      _emit(session, PlaybackState.focusChecking,
          '  $apiName0(0) 首报失败: $e');
    }

    // —— 主动解算滑块 (仅黑名单用户, 对齐浏览器 ek 在 componentDidMount 内主动挂载 ecaptcha) ——
    // 普通用户 (ev 组件) 不解算滑块, 直接走二次上报
    String? captchaToken;
    if (_isBlacklisted) {
      try {
        captchaToken = await _solveFocusCaptchaProactively();
        _emit(session, PlaybackState.focusChecking,
            captchaToken != null
                ? '  主动解算滑块成功: captchaToken=${captchaToken.substring(0, captchaToken.length > 16 ? 16 : captchaToken.length)}...'
                : '  主动解算未拿到 token, 二次上报不带 captchaToken');
      } catch (e) {
        _emit(session, PlaybackState.focusChecking, '  主动解算滑块异常: $e');
      }
    } else {
      _emit(session, PlaybackState.focusChecking,
          '  普通用户 (ev 组件), 跳过滑块解算, 直接二次上报');
    }

    // 模拟用户点击通过 (~2s, 快刷模式压缩等待)
    final clickDelay = _fastBrush
        ? const Duration(seconds: 2)
        : const Duration(seconds: 5);
    await Future.delayed(clickDelay);
    if (_cancelled) return;

    // —— 二次上报: 非黑名单→addVideoss / 黑名单→addVideocss (seriousCheckResult=2) ——
    // 仅黑名单用户携带 captchaToken
    final reportToken = _isBlacklisted ? captchaToken : null;
    final apiName2 = _isBlacklisted ? 'addVideocss' : 'addVideoss';
    try {
      await _sendVideoCheck(
        session,
        seriousCheckResult: 2,
        type: addVideoType,
        interactivePointId: interactivePointId,
        captchaToken: reportToken,
      );
      _emit(session, PlaybackState.focusChecking,
          reportToken != null && reportToken.isNotEmpty
              ? '  $apiName2(2) 二次上报 ok (黑名单用户, 携带 captchaToken)'
              : '  $apiName2(2) 二次上报 ok (无 captchaToken)');
    } catch (e) {
      _emit(session, PlaybackState.focusChecking, '  二次上报异常: $e');
    }

    // act=2 恢复 + 事件触发进度持久化
    final r2 = await _sendCollect(session, action: 2, stayMs: 0, pti: pti);
    _logCollectResult(session, r2, prefix: '    [act=2 检测点恢复] ');
    await _persistProgress(session);

    _emit(session, PlaybackState.playing, '继续播放...');
  }

  /// 认真度检测/互动点上报统一入口 (按黑名单状态自动选择接口)
  ///
  /// 对齐浏览器 homework-play-video chunk 的 ev/ek 组件分流:
  ///   - 非黑名单 ([_isBlacklisted]==false) → ev 组件 → [PlayerRemoteDataSource.addVideoss]
  ///     (ev 组件 _submitEarnestCheck 调用 ep 函数, 走 /student/addVideoss)
  ///   - 黑名单 ([_isBlacklisted]==true)    → ek 组件 → [PlayerRemoteDataSource.addVideocss]
  ///     (ek 组件 reportVideoPoint 走 /student/addVideocss)
  ///
  /// 两个接口请求体参数完全一致 (schoolId/homeworkId/lessonId/type/interactivePointId/
  /// platform/seriousCheckResult/captchaToken), 仅 URL 不同。
  Future<void> _sendVideoCheck(
    VideoSession session, {
    required int seriousCheckResult,
    required int type,
    String? interactivePointId,
    String? captchaToken,
  }) async {
    if (_isBlacklisted) {
      await _playerRemote.addVideocss(
        schoolId: session.schoolId,
        homeworkId: session.homeworkId,
        lessonId: session.lessonId,
        seriousCheckResult: seriousCheckResult,
        type: type,
        interactivePointId: interactivePointId,
        captchaToken: captchaToken,
      );
    } else {
      await _playerRemote.addVideoss(
        schoolId: session.schoolId,
        homeworkId: session.homeworkId,
        lessonId: session.lessonId,
        seriousCheckResult: seriousCheckResult,
        type: type,
        interactivePointId: interactivePointId,
        captchaToken: captchaToken,
      );
    }
  }

  /// 主动求解认真度检测滑块, 返回 captchaToken 或 null
  ///
  /// 对齐浏览器 ek 组件: 检测点首报的同时**主动**挂载并解算 ecaptcha 滑块,
  /// 而非等待服务端下发 017129/017130 风险码再被动弹窗。
  ///
  /// 复用项目已完成的 [CaptchaService] (滑块识别 + verify 扫描)。
  Future<String?> _solveFocusCaptchaProactively() async {
    try {
      final service = CaptchaService(
        bizCode: CryptoConstants.passwordCaptchaBizCode,
      );
      return await service.solveAutomatically();
    } catch (_) {
      return null;
    }
  }

  /// 解析认真度检测点的 interactivePointId
  ///
  /// 对齐 §3'.6: interactivePointId = interactiveVideo ? getInteractiveConfigDetail.id : null
  /// - 互动视频 (session.interactiveConfigs 非空): 取首个互动点的
  ///   getInteractiveConfigDetail.id 作为检测点 ID
  /// - 普通视频: 返回 null (与 HAR 一致, addVideoss 显式发送 null)
  Future<String?> _resolveFocusInteractivePointId(VideoSession session) async {
    final configs = session.interactiveConfigs;
    if (configs.isEmpty) return null;
    try {
      final detail = await _playerRemote.getInteractiveConfigDetail(
        configId: configs.first.id,
      );
      final id = detail['id']?.toString();
      if (id != null && id.isNotEmpty) return id;
    } catch (_) {}
    return null;
  }

  /// Stage 5: 结束序列 (对应 Python 结束流程)
  ///
  /// 2 playbackProgress → 余量心跳 → act=3 → act=4 → 1 playbackProgress
  Future<void> _finishPlayback(VideoSession session) async {
    _emit(session, PlaybackState.finishing, '结束序列 (2 playprog + 余量心跳 + act=3 + act=4 + 1 playprog)');

    // ⑩a playbackProgress ×2 (结束前)
    final pp1 = await _persistProgress(session);
    _emit(session, PlaybackState.finishing, '  playbackProgress #1: ${pp1 ? "ok" : "失败"}');
    if (_cancelled) return;
    final pp2 = await _persistProgress(session);
    _emit(session, PlaybackState.finishing, '  playbackProgress #2: ${pp2 ? "ok" : "失败"}');
    await Future.delayed(const Duration(milliseconds: 500));
    if (_cancelled) return;

    // ⑨a 余量心跳 (不足一个墙钟心跳的尾段)
    await _sendRemainderHeartbeat(session);
    if (_cancelled) return;

    // ⑨b 结束 burst: act=3 (暂停) + act=4 (视频自然结束, stay≈21ms, media=0)
    final r3 = await _sendCollect(session, action: 3, stayMs: 0, pti: _lastPti);
    _logCollectResult(session, r3, prefix: '    [act=3 结束暂停] ');
    if (_cancelled) return;
    final r4 = await _sendCollect(session,
        action: 4, stayMs: 21, pti: _lastPti, mediaMs: 0);
    _logCollectResult(session, r4, prefix: '    [act=4 END] ');

    // ⑩b playbackProgress ×1 (结束后)
    await Future.delayed(const Duration(milliseconds: 500));
    final pp3 = await _persistProgress(session);
    _emit(session, PlaybackState.finishing, '  playbackProgress #3 (最终): ${pp3 ? "ok" : "失败"}');

    _emit(session, PlaybackState.finishing,
        '会话统计: 心跳成功=$_heartbeatOkCount, 上报失败=$_collectFailCount, '
        '服务器时间同步=${_telemetryRemote.clock.syncCount}次 (diff=${_telemetryRemote.clock.diffMs}ms)');
  }

  /// 余量心跳 (对应 Python `_execute_collect_burst_end` 中 ⑨a)
  ///
  /// 倍速下: 媒体余量 = duration - pti*interval, 墙钟余量 = 媒体余量 / speed
  ///
  /// 快刷模式提前结束 (真实进度达阈值) 时跳过: 此时 _playedS 远小于 duration,
  /// 若按 mediaRemainderS = duration - pti*interval 计算会等待整个剩余时长
  /// (如 1173s 视频在 300s 提前结束 → 等待 873s = 14 分钟), 阻塞下一任务。
  Future<void> _sendRemainderHeartbeat(VideoSession session) async {
    // 快刷模式2: 一律跳过余量心跳的真实等待。
    //
    // 余量心跳设计用于正常播放补齐尾段 (mediaRemainder = duration - pti*interval),
    // 并「真实等待 realRemainderS 秒」模拟剩余播放。快刷2 下本地模拟位置
    // 只推进到 200s 左右 (pti×interval), 余量 = 985s → 等待 492s (8 分钟),
    // 表现为「卡住」。快刷2 进度由爆发入账 + 真实进度轮询驱动, 剩余进度由
    // _fastBrushBurstLoop 的下一轮课程会话 (续刷) 补齐, 无需模拟等待。
    // (仅作用于快刷模式2; 快刷模式1 保持原始行为)
    if (_fastBrush2) {
      _emit(session, PlaybackState.finishing,
          '  跳过余量心跳 (快刷模式2, 剩余进度由爆发轮次补齐)');
      return;
    }

    // 正常模式: 真实进度已达阈值时跳过 (避免提前结束时傻等剩余时长)
    if (_brushFinalRatio >= _completeRatio) {
      _emit(session, PlaybackState.finishing,
          '  跳过余量心跳 (真实进度已达阈值 ${(_brushFinalRatio * 100).toInt()}%)');
      return;
    }

    if (_playedS >= session.duration) return;

    final interval = _heartbeatInterval;
    final speed = _speed;
    final mediaRemainderS = max(
      0,
      session.duration - _ptiFloat.toInt() * interval,
    );
    final realRemainderS =
        speed > 0 ? (mediaRemainderS / speed).floor() : mediaRemainderS;
    if (realRemainderS <= 0) return;

    _emit(session, PlaybackState.finishing, '  余量心跳 ${realRemainderS}s (media=${mediaRemainderS}s, speed=${speed}x)');

    await Future.delayed(Duration(seconds: realRemainderS));
    if (_cancelled) return;

    _ptiFloat += mediaRemainderS / interval;
    _lastPti = _ptiFloat.toInt();
    _playedS = session.duration;
    session.playedTime = session.duration;

    final r = await _sendCollect(session,
        action: 2,
        stayMs: realRemainderS * 1000,
        pti: _lastPti,
        mediaMs: (mediaRemainderS * 1000).toInt());
    _logCollectResult(session, r, prefix: '    [余量心跳 act=2] ');
    _heartbeatOkCount++;
  }

  /// 查询真实进度比例 (0~1), 同时更新 _resumePlaytimeMs 供续刷
  ///
  /// 对应 Python: _execute_query_progress_ratio
  /// 优先 refreshTaskProgress, 回退 queryTaskProgress, 再回退 lessonTaskInfo.playTime/lessonTime
  Future<double> _queryProgressRatio(VideoSession session) async {
    double? ratio;

    // 1. refreshTaskProgress (taskId 维度)
    if (session.taskId.isNotEmpty && session.schoolId.isNotEmpty) {
      try {
        final list = await _playerRemote.refreshTaskProgressBatch(
          taskIds: [session.taskId],
          schoolId: session.schoolId,
        );
        if (list.isNotEmpty) {
          final item = list.first;
          final rv = item['ratio'];
          if (rv != null) {
            ratio = double.tryParse(rv.toString());
          }
          if (ratio == null) {
            final fp = item['finishPercent'] ?? item['percent'];
            if (fp != null) ratio = double.tryParse(fp.toString());
          }
        }
      } catch (_) {}
    }

    // 2. queryTaskProgress 兜底
    if (ratio == null && session.taskId.isNotEmpty) {
      try {
        final list = await _playerRemote.queryTaskProgress(
          taskIds: [session.taskId],
          schoolId: session.schoolId,
        );
        if (list.isNotEmpty) {
          final item = list.first;
          final rv = item['ratio'];
          if (rv != null) {
            ratio = double.tryParse(rv.toString());
          }
          if (ratio == null) {
            final fp = item['finishPercent'] ?? item['percent'];
            if (fp != null) ratio = double.tryParse(fp.toString());
          }
        }
      } catch (_) {}
    }

    // 3. lessonTaskInfo: 取 finishPlayTime(ms) 续刷 + 兜底 ratio
    //    周培优无 homeworkId, 该接口要求作业ID非空, 跳过 (对齐 Python: homework_id 为 None 时跳过)
    //
    //    续刷起点优先级: finishPlayTime > playTime (clamp 到 lessonTime)
    //    - finishPlayTime 是实际观看到的最后位置 (≤ lessonTime), 适合作为 seek 起点
    //    - playTime 是累积观看时长, 可能 > lessonTime (多次观看/回放累积),
    //      不适合直接作为 seek 起点, 仅在 finishPlayTime 缺失时回退并 clamp
    if (session.homeworkId.isNotEmpty) {
      try {
        final ti = await _playerRemote.getLessonTaskInfo(
          homeworkId: session.homeworkId,
          lessonId: session.lessonId,
          contentType: session.contentType,
          schoolId: session.schoolId,
        );
        final fpt = ti['finishPlayTime'];
        final pt = ti['playTime'];
        final lt = ti['lessonTime'];
        final ltVal = lt != null ? (double.tryParse(lt.toString()) ?? 0) : 0;
        // 续刷起点:
        // - 快刷模式: 用 playTime(累积观看时长, clamp 到 lessonTime)。
        //   实测 finishPlayTime 字段 = 完成阈值 (0.8×时长, 如 1265s 课时 = 1012s),
        //   并非"最后观看位置"; 首次观看(playTime=0)时若把 processTime 传为完成线,
        //   属于异常行为特征 (正常播放器不会首次上报就声称看到 80% 位置)。
        // - 正常模式: 保持 finishPlayTime 优先 (兼容原有续播语义)。
        if (_fastBrush && pt != null) {
          final ptVal = _parseIntField(pt);
          _resumePlaytimeMs = (ltVal > 0)
              ? ptVal.clamp(0, ltVal.toInt())
              : ptVal;
        } else if (fpt != null) {
          _resumePlaytimeMs = _parseIntField(fpt);
        } else if (pt != null) {
          final ptVal = _parseIntField(pt);
          _resumePlaytimeMs = (ltVal > 0)
              ? ptVal.clamp(0, ltVal.toInt())
              : ptVal;
        }
        // ratio 计算: 优先 finishPercent, 回退 finishPlayTime/lessonTime, 再回退 playTime/lessonTime (clamp 到 1.0)
        if (ratio == null) {
          final fp = ti['finishPercent'];
          if (fp != null) {
            ratio = double.tryParse(fp.toString());
          } else if (fpt != null && ltVal > 0) {
            final fptVal = double.tryParse(fpt.toString()) ?? 0;
            ratio = (fptVal / ltVal).clamp(0.0, 1.0);
          } else if (pt != null && ltVal > 0) {
            final ptVal = double.tryParse(pt.toString()) ?? 0;
            ratio = (ptVal / ltVal).clamp(0.0, 1.0);
          }
        }
        if (ratio == null) {
          final p = ti['percent'];
          if (p != null) ratio = double.tryParse(p.toString());
        }
      } catch (_) {}
    }

    return ratio ?? 0.0;
  }

  /// 执行单个互动点的完整流程 (在 interactiveTimePoint 触发时调用)
  ///
  /// 流程: getInteractiveConfigDetail → submitAnswer(空答取正确答案) →
  /// submitAnswer(正确答案) → addVideoss(0→2, interactivePointId=cfg.id, type=3)
  Future<void> _executeInteractivePoint(
    VideoSession session,
    InteractiveConfig cfg,
    int index,
    int total,
  ) async {
    if (_cancelled) return;

    _emit(session, PlaybackState.interactive,
        '互动点 ${index + 1}/$total (configId=${cfg.id}, timePoint=${cfg.timePoint}ms)');

    // 1. getInteractiveConfigDetail
    String? sceneId;
    String? questionId;
    try {
      final detail = await _playerRemote.getInteractiveConfigDetail(
        configId: cfg.id,
      );
      sceneId = detail['interactiveSceneId']?.toString();
      final q = detail['question'] as Map<String, dynamic>?;
      // questionId 兼容两种结构: question.id (主) / 顶层 questionId (兜底)
      questionId = q?['id']?.toString() ?? detail['questionId']?.toString();
      _emit(session, PlaybackState.interactive,
          '  getInteractiveConfigDetail: sceneId=$sceneId, questionId=$questionId');
    } catch (e) {
      _emit(session, PlaybackState.interactive,
          '  getInteractiveConfigDetail 失败: $e');
    }
    if (sceneId == null || sceneId.isEmpty || questionId == null) {
      _emit(session, PlaybackState.interactive,
          '  跳过: 缺少 sceneId/questionId');
      return;
    }

    // 2. submitAnswer 空答 → 取回正确答案
    String? correct;
    try {
      final r0 = await _playerRemote.submitInteractiveAnswer(
        interactiveSceneId: sceneId,
        questionId: questionId,
        myAnswers: [''],
        lessonId: session.lessonId,
      );
      final answers = (r0['answers'] as List<dynamic>?) ?? [];
      if (answers.isNotEmpty) correct = answers.first?.toString();
      _emit(session, PlaybackState.interactive,
          '  submitAnswer(空答): correct=${correct ?? "(无)"}');
    } catch (e) {
      _emit(session, PlaybackState.interactive,
          '  submitAnswer(空答) 失败: $e');
    }

    // 3. submitAnswer 正确答案
    if (correct != null && correct.isNotEmpty) {
      try {
        await _playerRemote.submitInteractiveAnswer(
          interactiveSceneId: sceneId,
          questionId: questionId,
          myAnswers: [correct],
          lessonId: session.lessonId,
        );
        _emit(session, PlaybackState.interactive,
            '  submitAnswer(正确答案) ok');
      } catch (e) {
        _emit(session, PlaybackState.interactive,
            '  submitAnswer(正确答案) 失败: $e');
      }
    }

    // 4. 认真度检测/互动点上报: seriousCheckResult 0 → 2
    //    互动视频 type=3, interactivePointId=cfg.id (从配置动态获取)
    //    非黑名单→addVideoss / 黑名单→addVideocss (对齐浏览器 ev/ek 组件)
    final apiName = _isBlacklisted ? 'addVideocss' : 'addVideoss';
    try {
      await _sendVideoCheck(
        session,
        seriousCheckResult: 0,
        type: 3,
        interactivePointId: cfg.id,
      );
      await _sendVideoCheck(
        session,
        seriousCheckResult: 2,
        type: 3,
        interactivePointId: cfg.id,
      );
      _emit(session, PlaybackState.interactive,
          '  $apiName(0→2) 记录通过 ok (ipId=${cfg.id})');
    } catch (e) {
      _emit(session, PlaybackState.interactive,
          '  $apiName 失败: $e');
    }
  }

  /// 互动流程收尾: refreshTaskProgress 刷新任务进度 + 标记完成
  Future<void> _finalizeInteractive(VideoSession session) async {
    if (_lessonInteractiveDone) return;

    // refreshTaskProgress 刷新任务进度
    if (session.taskId.isNotEmpty && session.schoolId.isNotEmpty && !_cancelled) {
      try {
        await _playerRemote.refreshTaskProgressBatch(
          taskIds: [session.taskId],
          schoolId: session.schoolId,
        );
        _emit(session, PlaybackState.interactive, '  refreshTaskProgress ok');
      } catch (e) {
        _emit(session, PlaybackState.interactive,
            '  refreshTaskProgress 失败: $e');
      }
    }

    _lessonInteractiveDone = true;
  }

  Future<bool> _persistProgress(VideoSession session) async {
    return _telemetryRemote.sendPlaybackProgress(
      userId: session.userId,
      token: session.token,
      lessonId: session.lessonId,
      playTime: session.playedTime,
    );
  }

  // ─── 遥测构建辅助 ───

  /// 构建本次会话的遥测上下文 (CommonPackage 级常量)
  TelemetryContext _ctx(VideoSession session) {
    return TelemetryContext(
      userId: session.userId,
      token: session.token,
      clientIp: session.clientIp,
      schoolId: session.schoolId,
      memberProvinceCode: session.memberProvinceCode,
      schoolProvinceCode: session.schoolProvinceCode,
      sdkVersion: _endpointConfig.sdkVersion,
      userAgent: _endpointConfig.userAgent,
      videoBizCode: AppConstants.defaultVideoBizCode,
      playerSn: AppConstants.playerSn,
    );
  }

  /// 发送一次 collect 上报 (对应 Python `_execute_send_collect`)
  ///
  /// 返回 [CollectResult] 供上层日志输出与服务器时间同步。
  /// [multiEvents] 每请求打包事件数 (EventPackage 长度, 默认 1 单事件),
  ///   快刷 burst 模式透传 fastBrushEventsPerRequest / maxBatchSize。
  Future<CollectResult> _sendCollect(
    VideoSession session, {
    required int action,
    required int stayMs,
    required int pti,
    int? mediaMs,
    int multiEvents = 1,
  }) async {
    // 对齐 Python: video_type = 6 if contentType == 11 else 1
    // (tasks/player_behavior.py L444: 校本视频 contentType=11 → video_type=6)
    final videoType = session.contentType == 11 ? 6 : 1;
    try {
      final result = await _telemetryRemote.sendCollectBatch(
        ctx: _ctx(session),
        sessionId: session.sessionId,
        secret: session.secret,
        lessonId: session.lessonId,
        courseId: session.courseId ?? session.lessonId,
        action: action,
        stayTime: stayMs,
        beginTs: _beginTs,
        pointTimeId: pti,
        pointNum: _pointNum,
        uuid: _nextUuid(),
        mediaTime: mediaMs,
        speed: _speed,
        videoType: videoType,
        useBackup: _useBackup,
        reportBackend: _reportBackend,
        multiEvents: multiEvents,
      );
      if (!result.isOk) _collectFailCount++;
      return result;
    } catch (e) {
      _collectFailCount++;
      return CollectResult(
        host: 'none',
        fallback: 0,
        httpStatus: 0,
        code: 0,
        msg: 'exception',
        serverTs: null,
        success: false,
        signature: '',
        reportTime: _telemetryRemote.clock.now(),
        error: '$e',
      );
    }
  }

  /// 铸造快刷模式2 会话池 (多 session 预算乘法专用)
  ///
  /// 并发调用 [PlayerRemoteDataSource.getPlayerGlobalConf] N 次, 每次返回
  /// 一个新 sessionId+secret (服务端不限频、不绑定会话连续性, 审计报告 04 §2.2)。
  /// 预算键 = x-bfe-session-id, 因此每个新会话自带独立 ~45s 初始信用预算。
  ///
  /// 铸造失败的槽位回退主会话配置 (VideoSession.sessionId/secret); 全部失败
  /// 时返回单槽主会话 (退化为普通单会话爆发, 不放大也不报错)。
  Future<List<_SessionConf>> _mintSessions(VideoSession session) async {
    final main = _SessionConf(
      session.sessionId,
      session.secret,
      session.clientIp,
    );
    final confs = await Future.wait([
      for (var i = 0; i < _fastBrushSessions; i++) _fetchGlobalConfForMint(),
    ]);
    final minted = confs.whereType<_SessionConf>().toList();
    if (minted.isEmpty) {
      _emit(session, PlaybackState.playing,
          '  会话铸造全部失败, 回退主会话 (单会话爆发, 无乘法放大)');
      return [main];
    }
    _emit(session, PlaybackState.playing,
        '  会话铸造 ${minted.length}/$_fastBrushSessions 成功 '
        '(每会话独立 ~45s 初始预算, 旧会话跨轮耗尽后本轮重置)');
    return minted;
  }

  /// 单次 getPlayerGlobalConf 铸造 (失败返回 null, 不抛异常)
  Future<_SessionConf?> _fetchGlobalConfForMint() async {
    try {
      final conf = await _playerRemote
          .getPlayerGlobalConf()
          .timeout(const Duration(seconds: 10));
      final globalInfo =
          (conf['globalInfo'] as Map<String, dynamic>?) ?? const {};
      final sid = globalInfo['sessionId']?.toString() ??
          conf['sessionId']?.toString() ??
          '';
      final secret = globalInfo['secret']?.toString() ??
          conf['secret']?.toString() ??
          '';
      if (sid.isEmpty || secret.isEmpty) return null;
      return _SessionConf(
        sid,
        secret,
        globalInfo['clientIp']?.toString() ??
            conf['clientIp']?.toString() ??
            '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 向指定端点以指定会话发送一次 collect 上报 (快刷模式2 专用)
  ///
  /// 对齐 probe11_multisession.py 的 send(): 单事件请求 (multiEvents=1),
  /// action=2, fallback=0, 签名 duration = stayMs; CommonPackage.ip 使用
  /// 铸造会话自带的 clientIp (为空时回退主会话)。
  Future<CollectResult> _sendCollectToHost(
    VideoSession session, {
    required String host,
    required _SessionConf conf,
    required int action,
    required int stayMs,
    required int pti,
    int? mediaMs,
  }) async {
    // 对齐 Python: video_type = 6 if contentType == 11 else 1
    final videoType = session.contentType == 11 ? 6 : 1;
    final ctx = TelemetryContext(
      userId: session.userId,
      token: session.token,
      clientIp: conf.clientIp.isNotEmpty ? conf.clientIp : session.clientIp,
      schoolId: session.schoolId,
      memberProvinceCode: session.memberProvinceCode,
      schoolProvinceCode: session.schoolProvinceCode,
      sdkVersion: _endpointConfig.sdkVersion,
      userAgent: _endpointConfig.userAgent,
      videoBizCode: AppConstants.defaultVideoBizCode,
      playerSn: AppConstants.playerSn,
    );
    try {
      final result = await _telemetryRemote.sendCollectBatchToHost(
        host: host,
        ctx: ctx,
        sessionId: conf.sessionId,
        secret: conf.secret,
        lessonId: session.lessonId,
        courseId: session.courseId ?? session.lessonId,
        action: action,
        stayTime: stayMs,
        beginTs: _beginTs,
        pointTimeId: pti,
        pointNum: _pointNum,
        uuid: _nextUuid(),
        mediaTime: mediaMs,
        speed: _speed,
        videoType: videoType,
      );
      if (!result.isOk) _collectFailCount++;
      return result;
    } catch (e) {
      _collectFailCount++;
      return CollectResult(
        host: host,
        fallback: 0,
        httpStatus: 0,
        code: 0,
        msg: 'exception',
        serverTs: null,
        success: false,
        signature: '',
        reportTime: _telemetryRemote.clock.now(),
        error: '$e',
      );
    }
  }

  /// 将 [CollectResult] 输出到进度流 (供 UI 日志显示)
  ///
  /// [prefix] 行前缀 (用于区分起始 burst / 心跳 / 检测点暂停 / 结束等)
  /// [extra] 附加信息 (如 pti/played/stay/media, 与服务器响应并排显示)
  void _logCollectResult(
    VideoSession session,
    CollectResult r, {
    String prefix = '',
    String extra = '',
  }) {
    final sb = StringBuffer(prefix);
    sb.write('host=${r.host}');
    if (r.fallback > 0) sb.write('(+fallback$r.fallback)');
    sb.write(' code=${r.code}');
    if (r.serverTs != null) {
      sb.write(' ts=${r.serverTs}');
    }
    sb.write(' ok=${r.isOk}');
    if (r.msg.isNotEmpty && r.msg != 'ok') {
      sb.write(' msg=${r.msg}');
    }
    if (r.error != null) sb.write(' err=${r.error}');
    if (extra.isNotEmpty) sb.write(' | $extra');
    _emit(session, PlaybackState.playing, sb.toString());
  }

  /// 生成下一个上报 UUID (8 位随机前缀_递增序号)
  String _nextUuid() {
    _uuidSeq += 1;
    return '${_uuidPrefix}_$_uuidSeq';
  }

  /// 生成 8 位随机字符的会话 UUID 前缀
  String _genUuidPrefix() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List.generate(8, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  void _emit(
    VideoSession session,
    PlaybackState state,
    String? message, {
    String? error,
  }) {
    if (_progressController.isClosed) return;
    _progressController.add(PlaybackProgress(
      state: state,
      playedSeconds: session.playedTime,
      totalSeconds: session.duration,
      message: message,
      error: error,
    ));
  }

  /// 快刷模式2 请求轮流分发的上报端点 (功能等价的入库通道, 审计报告 04 §4)
  static const _ms2Hosts = ['bfe', 'clog', 'dlog'];

  /// 快刷模式2 单会话单轮信用预算 (ms)
  ///
  /// probe11c 实测每个新 session 初始预算 ~45s; 取 40s (10 请求 × 4s)
  /// 保证整组声明落在预算内全部入账, 不触发软钳制。
  static const _ms2SessionBudgetMs = 40000;
}

/// 快刷模式2 铸造会话 (一次 getPlayerGlobalConf 调用签发的独立预算维度)
class _SessionConf {
  final String sessionId;
  final String secret;
  final String clientIp;

  const _SessionConf(this.sessionId, this.secret, this.clientIp);
}
