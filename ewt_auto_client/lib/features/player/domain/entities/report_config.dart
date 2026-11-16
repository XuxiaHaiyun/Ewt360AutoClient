/// 进度上报配置
///
/// 对应 Python: gui/dialogs/report_config.py ReportConfigDialog 配置项
class ReportConfig {
  /// 是否跳过已观看完成课程 (taskStatus==30)
  final bool filterCompleted;

  /// 是否跳过已完成认真度检测课程 (seriousCheckResult==2, 已通过)
  final bool filterSeriousCheckChecked;

  /// 选中的 contentType 列表
  /// (null=全部, 1=视频, 2=试卷, 3=FM, 4=资讯, 5=板报, 6=测评, 7=课后习题,
  ///  11=校本视频, 12=校本试卷, 13=模拟选科, 14=B端测评, 15=专题, 16=课程包,
  ///  17=直播, 18=选科测评, 19=专题, 20=学科专项, 21=模拟选科决策分析)
  final List<int?> selectedTypes;

  /// 选中的课程学科名称列表
  final List<String> selectedSubjects;

  /// 心跳周期 (秒, 仅正常模式生效)
  final int heartbeatInterval;

  /// 播放倍速 (1.0=原速, 2.0=2倍速)
  final double speed;

  /// 是否使用备用上报通道 (clog/dlog)
  final bool useBackup;

  /// 备用通道上报端点 ("clog"/"dlog")
  final String reportBackend;

  /// 快刷模式
  final bool fastBrush;

  /// 快刷模式2 (多 session 预算乘法, V8)
  ///
  /// 服务端进度限速预算以客户端可控的 x-bfe-session-id 为键, 每个 session
  /// 独立核算信用 (~45s 初始预算), 与端点数无关。开启后每轮铸造
  /// [fastBrushSessions] 个新会话 (getPlayerGlobalConf 每次返回新
  /// sessionId+secret), 请求轮流分发到 bfe/clog/dlog 三端点并发上报,
  /// 信用随会话数近线性放大 (实测 N=8: 80 请求 3.7s 净增 +192s, 零硬拒绝)。
  final bool fastBrush2;

  /// 快刷模式2 每轮铸造 session 数 (1~50, 默认 8)
  ///
  /// 每个 session 由独立的 getPlayerGlobalConf 调用签发 (免费无频控),
  /// 自带独立 ~45s 初始限速预算; 总信用 ≈ session 数 × 每会话预算。
  final int fastBrushSessions;

  /// 快刷最大重刷轮数 (0=自动)
  final int fastBrushMaxRounds;

  /// 重刷模式(刷时长): 每课固定轮数, 每轮目标 = 已刷时长 + 额外分钟
  final bool rebrush;

  /// 重刷模式每课最大轮数 (硬约束, 默认 1)
  final int rebrushRounds;

  /// 重刷模式每轮额外时长 (分钟, 默认 40)
  final int rebrushExtraMinutes;

  /// 补偿检测模式: 仅补偿认真度/互动点上报, 不刷进度
  final bool compensate;

  /// 快刷并发线程数 (对一个课程同时发包的线程数, 默认 10)
  ///
  /// 仅快刷模式生效。每个线程独立向同一课程发送 collect 包 (多事件打包),
  /// 线程间无真实等待 (爆发 burst), 由网络往返自然节流。
  /// 对齐 Python BURST_THREADS。
  final int fastBrushThreads;

  /// 单次事件停留时长 (ms, 默认 10000), 对齐 Python STAY_TIME。
  ///
  /// 每个 collect 事件的 stay_time / 单事件 media_time 增量。
  /// 快刷模式每轮爆发累加 play_ms = 成功线程数 × 每请求事件数 × STAY_TIME × 倍速。
  final int fastBrushStayTime;

  /// 爆发轮次间真实等待 (秒, 默认 10), 对齐 Python POLL_INTERVAL。
  ///
  /// 每轮爆发 (BURST_THREADS 并发 collect) 后等待此秒数, 再轮询真实进度。
  final int fastBrushPollInterval;

  /// 每请求打包事件数 (0=自动, 默认 0), 对齐 Python EVENTS_PER_REQUEST。
  ///
  /// 0 时使用服务端 maxBatchSize (默认 10)。每个线程单次请求携带该数量的
  /// EventPackage 事件, 事件 media_time 依次递增 STAY_TIME。
  final int fastBrushEventsPerRequest;

  /// 风控(WAF)冷却秒数 (默认 120), 对齐 Python WAF_BACKOFF。
  ///
  /// 单轮爆发失败数超过成功数时, 判定触发风控, 暂停该秒数后继续。
  final int fastBrushWafBackoff;

  /// 完成阈值 (0.0~1.0, 默认 0.8)
  ///
  /// 真实进度 ratio >= 此值时, 任务标记为完成并显示 100%。
  /// 对应 TaskProgressDialog.completionThreshold。
  final double completionThreshold;

  /// 是否从上次进度开始 (默认 true)
  ///
  /// 开启时:
  /// - 真实播放: 视频加载后 seek 到服务端 playTime 位置
  /// - 进度上报(正常模式): 引擎以 playTime 为已上报进度起点
  /// - 进度上报(快刷模式): 首轮即从 playTime 续刷 (而非从 0 开始)
  ///
  /// 关闭时: 真实播放和进度上报均从 0 开始 (快刷模式保留原有"首轮从 0, 后续轮从 playTime"行为)。
  final bool resumeFromServer;

  /// 真实进度查询 (默认 true, 普通模式和快刷模式都可用)
  ///
  /// 开启时: 引擎周期性查询服务端真实进度, 达到 [completionThreshold] 后
  ///   提前结束当前任务并跳到下一个任务。
  /// 关闭时: 不查询服务端真实进度, 使用本地模拟进度跑完整个播放循环。
  final bool realProgressQuery;

  /// 真实进度轮询间隔 (秒, 默认 60, 仅 [realProgressQuery]=true 时生效)
  ///
  /// 控制进度弹窗 UI 和引擎内部查询服务端真实进度的频率。
  /// 间隔越小, 进度栏更新越及时, 但 API 调用越多。
  /// 引擎内部轮询和弹窗 UI 轮询均使用此值。
  final int progressPollInterval;

  /// 并行执行模式 (默认 false)
  ///
  /// 开启时: [executeBatch] 按 [parallelTaskCount] 并发执行多个任务。
  /// 关闭时: 顺序执行 (一次一个任务)。
  final bool parallelExecution;

  /// 并行任务数 (1~100, 默认 2, 仅 [parallelExecution]=true 时生效)
  final int parallelTaskCount;

  /// 自定义模式 (QuickJS 脚本上报, 默认 false)
  ///
  /// 开启后进度上报不再走内置引擎 (心跳/快刷), 而是执行 [customScript]。
  /// 脚本内可使用账号字段 `account`、任务字段 `task` 以及宿主函数:
  /// `log` / `sendRequest` / `parseJson` / `updateProgress` / `sleep` /
  /// `getPlayerToken` / `sendHeartbeat` / `queryProgress` / `completeMission` 等。
  final bool customEnabled;

  /// 自定义上报脚本 (QuickJS, 需定义并调用 async function main())
  final String customScript;

  /// V7 · 任意用户进度注入 (CommonPackage.userid 越权写, 默认 false)
  ///
  /// BFE collect/batch 的进度写入目标由 `CommonPackage.userid` 决定, token
  /// 仅做认证不做授权 (见安全测试报告 01_主报告 V7)。开启后所有上报请求的
  /// `CommonPackage.userid` / `TrUserId` 覆盖为 [injectTargetUserId],
  /// 进度写入目标用户而非当前登录账号 (正常/快刷/重刷模式经 VideoSession,
  /// 自定义模式经 account.userId 注入脚本运行时)。
  final bool injectUserId;

  /// V7 注入目标 userid (纯数字串, [injectUserId]=true 时生效)
  final String injectTargetUserId;

  /// 快刷模式3 (round15 多账户批量注入, 默认 false)
  ///
  /// 对齐 output/app/src_demo_round15.py: 多个操作者账户 (各自独立
  /// token/session/secret) barrier 并发向受害目标 (= 当前登录账号,
  /// 包体 userid 指向目标而 token 仅认证) 的课时注入进度;
  /// 每 pti 窗口内每操作者 1 包, 轮间等待窗口滚动, 达标即停。
  final bool fastBrush3;

  /// 快刷3 轮间等待秒数 (等 pti 窗口滚动, 默认 45, 对齐 ROUND_GAP)
  final int fast3RoundGap;

  /// 快刷3 操作者账号 userId 列表 (从已保存账号选取, 仅密码登录账号)
  ///
  /// 执行时按 userId 从 AccountStorage 解析会话; token 失效时用记住的
  /// 密码自动重新登录并回写存储。
  final List<String> operatorUserIds;

  const ReportConfig({
    this.filterCompleted = true,
    this.filterSeriousCheckChecked = false,
    this.selectedTypes = const [1, 3, 11],
    this.selectedSubjects = const [],
    this.heartbeatInterval = 60,
    this.speed = 1.0,
    this.useBackup = false,
    this.reportBackend = 'clog',
    this.fastBrush = false,
    this.fastBrush2 = false,
    this.fastBrushSessions = 8,
    this.fastBrushMaxRounds = 0,
    this.rebrush = false,
    this.rebrushRounds = 1,
    this.rebrushExtraMinutes = 40,
    this.compensate = false,
    this.fastBrushThreads = 10,
    this.fastBrushStayTime = 10000,
    this.fastBrushPollInterval = 10,
    this.fastBrushEventsPerRequest = 0,
    this.fastBrushWafBackoff = 120,
    this.completionThreshold = 0.8,
    this.resumeFromServer = true,
    this.realProgressQuery = true,
    this.progressPollInterval = 60,
    this.parallelExecution = false,
    this.parallelTaskCount = 2,
    this.customEnabled = false,
    this.customScript = '',
    this.injectUserId = false,
    this.injectTargetUserId = '',
    this.fastBrush3 = false,
    this.fast3RoundGap = 45,
    this.operatorUserIds = const [],
  });

  /// 是否包含全部类型（不过滤）
  bool get isAllTypes => selectedTypes.contains(null);

  /// 检查某个 contentType 是否应被上报
  bool shouldReportType(int? contentType) {
    if (isAllTypes) return true;
    return selectedTypes.contains(contentType);
  }

  /// 检查某个学科是否应被上报
  ///
  /// 与 Python 一致: 学科必须精确命中 selectedSubjects 才保留,
  /// 空学科/未知学科会被排除 (而非放行)。
  bool shouldReportSubject(String? subject) {
    if (selectedSubjects.isEmpty) return true;
    if (subject == null || subject.isEmpty) return false;
    return selectedSubjects.contains(subject);
  }

  /// V7 注入生效时返回目标 userid, 未开启或目标非法 (非纯数字) 返回 null
  ///
  /// CommonPackage.userid 为整型 (`int.tryParse(ctx.userId) ?? 0`),
  /// 非数字目标只会得到 userid=0 无意义, 故此处直接判非法。
  String? get effectiveInjectUserId {
    if (!injectUserId) return null;
    final v = injectTargetUserId.trim();
    return int.tryParse(v) != null ? v : null;
  }

  // ─── 序列化 (配置持久化: 进度上报配置弹窗) ───

  /// 序列化为 JSON (null 元素保留, 便于持久化往返)
  Map<String, dynamic> toJson() => {
        'filterCompleted': filterCompleted,
        'filterSeriousCheckChecked': filterSeriousCheckChecked,
        'selectedTypes': selectedTypes,
        'selectedSubjects': selectedSubjects,
        'heartbeatInterval': heartbeatInterval,
        'speed': speed,
        'useBackup': useBackup,
        'reportBackend': reportBackend,
        'fastBrush': fastBrush,
        'fastBrush2': fastBrush2,
        'fastBrushSessions': fastBrushSessions,
        'fastBrushMaxRounds': fastBrushMaxRounds,
        'rebrush': rebrush,
        'rebrushRounds': rebrushRounds,
        'rebrushExtraMinutes': rebrushExtraMinutes,
        'compensate': compensate,
        'fastBrushThreads': fastBrushThreads,
        'fastBrushStayTime': fastBrushStayTime,
        'fastBrushPollInterval': fastBrushPollInterval,
        'fastBrushEventsPerRequest': fastBrushEventsPerRequest,
        'fastBrushWafBackoff': fastBrushWafBackoff,
        'completionThreshold': completionThreshold,
        'resumeFromServer': resumeFromServer,
        'realProgressQuery': realProgressQuery,
        'progressPollInterval': progressPollInterval,
        'parallelExecution': parallelExecution,
        'parallelTaskCount': parallelTaskCount,
        'customEnabled': customEnabled,
        'customScript': customScript,
        'injectUserId': injectUserId,
        'injectTargetUserId': injectTargetUserId,
        'fastBrush3': fastBrush3,
        'fast3RoundGap': fast3RoundGap,
        'operatorUserIds': operatorUserIds,
      };

  /// 从 JSON 解析 (缺失/非法字段回退默认值)
  factory ReportConfig.fromJson(Map<String, dynamic> json) {
    List<int?> parseTypes(dynamic v) {
      if (v is! List) return const [1, 3, 11]; // 缺失/非法 → 默认类型
      final out = <int?>[];
      for (final e in v) {
        if (e == null) {
          out.add(null);
        } else {
          out.add(int.tryParse(e.toString()));
        }
      }
      return out;
    }

    List<String> parseSubjects(dynamic v) {
      if (v is! List) return const [];
      return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
    }

    // 数值字段容错: 仅接受 num (int/double), 其他类型 (String 等) 回退 null
    int? toInt(dynamic v) => v is num ? v.toInt() : null;
    double? toDouble(dynamic v) => v is num ? v.toDouble() : null;

    final d = json;
    return ReportConfig(
      filterCompleted: d['filterCompleted'] as bool? ?? true,
      filterSeriousCheckChecked:
          d['filterSeriousCheckChecked'] as bool? ?? false,
      selectedTypes: parseTypes(d['selectedTypes']),
      selectedSubjects: parseSubjects(d['selectedSubjects']),
      heartbeatInterval: toInt(d['heartbeatInterval']) ?? 60,
      speed: toDouble(d['speed']) ?? 1.0,
      useBackup: d['useBackup'] as bool? ?? false,
      reportBackend: d['reportBackend']?.toString() ?? 'clog',
      fastBrush: d['fastBrush'] as bool? ?? false,
      fastBrush2: d['fastBrush2'] as bool? ?? false,
      fastBrushSessions: toInt(d['fastBrushSessions']) ?? 8,
      fastBrushMaxRounds: toInt(d['fastBrushMaxRounds']) ?? 0,
      rebrush: d['rebrush'] as bool? ?? false,
      rebrushRounds: toInt(d['rebrushRounds']) ?? 1,
      rebrushExtraMinutes: toInt(d['rebrushExtraMinutes']) ?? 40,
      compensate: d['compensate'] as bool? ?? false,
      fastBrushThreads: toInt(d['fastBrushThreads']) ?? 10,
      fastBrushStayTime: toInt(d['fastBrushStayTime']) ?? 10000,
      fastBrushPollInterval: toInt(d['fastBrushPollInterval']) ?? 10,
      fastBrushEventsPerRequest: toInt(d['fastBrushEventsPerRequest']) ?? 0,
      fastBrushWafBackoff: toInt(d['fastBrushWafBackoff']) ?? 120,
      completionThreshold: toDouble(d['completionThreshold']) ?? 0.8,
      resumeFromServer: d['resumeFromServer'] as bool? ?? true,
      realProgressQuery: d['realProgressQuery'] as bool? ?? true,
      progressPollInterval: toInt(d['progressPollInterval']) ?? 60,
      parallelExecution: d['parallelExecution'] as bool? ?? false,
      parallelTaskCount: toInt(d['parallelTaskCount']) ?? 2,
      customEnabled: d['customEnabled'] as bool? ?? false,
      customScript: d['customScript'] is String ? d['customScript'] as String : '',
      injectUserId: d['injectUserId'] as bool? ?? false,
      injectTargetUserId: d['injectTargetUserId']?.toString() ?? '',
      fastBrush3: d['fastBrush3'] as bool? ?? false,
      fast3RoundGap: toInt(d['fast3RoundGap']) ?? 45,
      operatorUserIds: parseSubjects(d['operatorUserIds']),
    );
  }
}
