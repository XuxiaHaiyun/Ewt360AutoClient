/// 进度上报配置页：选择上报模式（正常/快刷1-3/重刷/补偿检测/自定义 QuickJS），
/// 各模式配置独立持久化到 SharedPreferences，支持选取操作者账号与编辑自定义 JS 脚本。
library;

import 'dart:convert';

import 'package:code_text_field/code_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/layout/app_breakpoints.dart';
import '../../../../features/settings/presentation/providers/settings_provider.dart';
import '../../domain/entities/report_config.dart';
import '../dialogs/operator_account_picker_dialog.dart';

/// JetBrains (IntelliJ Darcula) 风格 JS 高亮配色
final Map<String, TextStyle> _kJetBrainsCodeStyles = {
  'root': const TextStyle(color: Color(0xFFA9B7C6)), // 默认文本
  'keyword': const TextStyle(color: Color(0xFFCC7832)), // 橙色
  'built_in': const TextStyle(color: Color(0xFFD0D0FF)), // 内置对象
  'literal': const TextStyle(color: Color(0xFFCC7832)),
  'number': const TextStyle(color: Color(0xFF6897BB)), // 蓝色
  'string': const TextStyle(color: Color(0xFF6A8759)), // 绿色
  'comment': const TextStyle(color: Color(0xFF808080), fontStyle: FontStyle.italic),
  'title': const TextStyle(color: Color(0xFFFFC66D)), // 函数名 黄色
  'function': const TextStyle(color: Color(0xFFFFC66D)),
  'symbol': const TextStyle(color: Color(0xFF6897BB)),
  'regexp': const TextStyle(color: Color(0xFF6A8759)),
  'params': const TextStyle(color: Color(0xFFA9B7C6)),
  'meta': const TextStyle(color: Color(0xFFBBB529)),
  'type': const TextStyle(color: Color(0xFFFFC66D)),
  'attr': const TextStyle(color: Color(0xFFE8BF6A)),
  'name': const TextStyle(color: Color(0xFFFFC66D)),
  'variable': const TextStyle(color: Color(0xFFA9B7C6)),
  'property': const TextStyle(color: Color(0xFFE8BF6A)),
  'operator': const TextStyle(color: Color(0xFFA9B7C6)),
};

/// 进度上报配置持久化键
const String _kReportModeKey = 'ewt_report_mode_v1';
const String _kReportConfigPrefix = 'ewt_report_config_v1_';

/// 上报模式
enum ReportMode { normal, fast, fast2, fast3, rebrush, compensate, custom }

const Map<ReportMode, String> _modeKeys = {
  ReportMode.normal: 'normal',
  ReportMode.fast: 'fast',
  ReportMode.fast2: 'fast2',
  ReportMode.fast3: 'fast3',
  ReportMode.rebrush: 'rebrush',
  ReportMode.compensate: 'compensate',
  ReportMode.custom: 'custom',
};

const Map<ReportMode, String> _modeLabels = {
  ReportMode.normal: '正常模式',
  ReportMode.fast: '快刷模式',
  ReportMode.fast2: '快刷模式2',
  ReportMode.fast3: '快刷模式3',
  ReportMode.rebrush: '重刷模式',
  ReportMode.compensate: '补偿检测模式',
  ReportMode.custom: '自定义(QuickJS)',
};

/// 各模式的默认配置 (独立, 互不干扰)
///
/// 快刷模式默认对齐 ewt360_lite_client_final_v4.py 的快刷配置:
///   SPEED=2.0, STAY_TIME=10000, POLL_INTERVAL=10, EVENTS_PER_REQUEST=0,
///   BURST_THREADS=20, WAF_BACKOFF=120, intervalTime=60,
///   COMPLETE_PERCENT="100" (Python 对齐值; 本工程完成阈值统一改为 80%,
///   不再沿用 Python 的 100%, 避免刷满全程), PARALLEL_COURSES=100 (并行 100 任务)。
/// 其中 MAX_ROUNDS=600 为全局重刷上限, 对应本工程的"自动估算轮数" (fastBrushMaxRounds=0),
/// 因此快刷模式默认 fastBrushMaxRounds=0 (自动)。
/// 重刷模式 (基于普通模式行为链) 仅保留该脚本 v5 的 REBRUSH_EXTRA_MINUTES=60
/// (每轮额外 60 分钟) 参数, 其余沿用普通模式默认。
/// 若用户从未手动保存过对应模式配置, 则使用以上默认; 一旦用户保存过, 即以其保存值为准。
///
/// 自定义模式示例脚本存放于 assets/scripts/custom_report_example.js
/// (行为链与普通模式 PlaybackEngine 完全对齐: 初始化 → record/submit →
/// 起始 burst → 心跳循环(检测点/互动点/周期持久化/真实进度轮询) →
/// 结束序列; 默认配置脚本内硬编码, 与普通模式默认一致)。
/// 脚本文件由 [rootBundle] 异步加载, 见 [_loadExampleScript]。
const String kCustomExampleScriptAsset =
    'assets/scripts/custom_report_example.js';

/// 加载自定义模式示例脚本 (assets 资源)
///
/// 资源缺失/读取失败时返回空字符串 (调用方决定回退行为)。
Future<String> _loadExampleScript() async {
  try {
    return await rootBundle.loadString(kCustomExampleScriptAsset);
  } catch (_) {
    return '';
  }
}

/// 快刷模式2 默认参数「速调表」——改这里即可调整快刷模式2的默认值。
///
/// 注意：本表仅作用于「快刷模式2」(fast2)，快刷模式1 (fast) 保持原始默认。
/// 2026-09-25 重写为 V8 多 session 预算乘法 (probe11/probe11c 干净课程重测)：
/// - 机制：服务端限速预算键 = 客户端可控的 x-bfe-session-id，每个 session
///   独立核算信用（~45s 初始预算），与端点数无关。每轮铸造 [kFast2Sessions]
///   个新会话（getPlayerGlobalConf 每次返回新 sessionId+secret，免费无频控），
///   请求轮流分发到 bfe/clog/dlog，信用随会话数近线性放大
///   （干净课程实测 N=1/4/8 → 净增 40/148/192s，80 并发零硬拒绝）。
/// - 每会话单轮信用压在 ~40s 预算内：每会话请求数 = 40s ~/ (stay×speed)，
///   上限 = 并发线程数；超预算部分被静默软钳制不入账（rej 仍为 0），宁少勿多。
/// - 每轮铸造新会话重置预算窗口（旧会话跨轮耗尽），对齐 probe11 每相重新 mint。
/// - 单请求声明 stay×speed 必须是合理小块：大额单声明会被"真实进度读"防御
///   钳制为 0；多 session 拆分的小额声明各自落在各自会话窗口内，不被钳制。
/// - 延迟入账约 30s：进度轮询间隔 35s（≥入账延迟），避免误判无入账触发
///   预算耗尽提前退出。
/// - 每请求事件数必须 = 1：多事件批量会被钳制，单事件 × 多会话才有效。
/// - 完成判定被拦截：playTime 超阈值后 finished 仍 None（在完成判定层，
///   非入账层），故 completionThreshold=0.8 刷满进度即可，不追求 finished=true。
const int kFast2HeartbeatInterval = 15; // 快刷2 轮间等待(秒)。少量爆发+多轮, 单轮内多会话预算独立不受限
const double kFast2CompletionThreshold = 0.8; // 快刷2 完成阈值。全局统一 80% (与服务端 finishPercent=0.8 一致)
const int kFast2EventsPerRequest = 1; // 快刷2 每请求事件数。必须 1（多事件批量会被钳制）
const int kFast2ProgressPollInterval = 35; // 快刷2 真实进度轮询间隔(秒)。≥延迟入账30s,避免误判无入账
const int kFast2Sessions = 8; // 快刷2 每轮铸造 session 数。probe11c 实测 N=8: 80 请求 3.7s 净增 +192s, 零硬拒绝

/// 快刷模式3 默认参数「速调表」——改这里即可调整快刷模式3的默认值。
///
/// 对齐 round15 SRC 危害演示 (src_demo_round15.py, 2026-09-27):
/// - 多操作者集群: 从已保存账号中选取 (密码账号可自动重登; 短信/扫码账号
///   token 检测有效后可选), 每操作者独立
///   token/BFE 会话/secret, 执行前检测 token, 失效自动重新登录;
/// - 受害目标 = 当前登录账号 (包体 userid 指向目标, 不可编辑);
/// - 每轮每操作者 1 包 (barrier 并发), 端点轮换 bfe/clog/dlog,
///   pti = (全局包序 % point_num) + 1 跨轮分布, 单轮入账 ≈ point_num×26s;
/// - 轮间等待 45s 等 pti 窗口滚动, 每轮观测 15s 后查真实进度, 达标即停;
/// - 单包 stay=10s / speed=2.0 / 单事件 (与真实播放形态无异)。
const int kFast3RoundGap = 45; // 轮间等待秒数 (ROUND_GAP, 等 pti 窗口滚动)
const double kFast3Speed = 2.0; // 单包声明倍速 (speed=2.0 合法值)
const double kFast3CompletionThreshold = 0.8; // 完成阈值 (全局统一 80%)

ReportConfig _defaultConfigForMode(ReportMode mode) {
  switch (mode) {
    case ReportMode.normal:
      return const ReportConfig();
    case ReportMode.fast:
      // 快刷模式1：保持原始默认（完成阈值按全局统一改为 80%）
      return const ReportConfig(
        fastBrush: true,
        fastBrushMaxRounds: 0,
        fastBrushThreads: 20,
        fastBrushWafBackoff: 120,
        fastBrushEventsPerRequest: 0,
        fastBrushStayTime: 10000,
        fastBrushPollInterval: 10,
        speed: 2.0,
        heartbeatInterval: 60,
        completionThreshold: 0.8,
        parallelExecution: true,
        parallelTaskCount: 100,
      );
    case ReportMode.fast2:
      // V8 多 session 预算乘法 (2026-09-25 重写): 每轮铸造 8 个独立会话,
      // 每会话请求数 = 40s ~/ (stay×speed), 上限 = 并发线程数;
      // 请求轮流分发到 bfe/clog/dlog, 信用随会话数近线性放大。
      return const ReportConfig(
        fastBrush: true,
        fastBrush2: true,
        fastBrushSessions: kFast2Sessions,
        fastBrushMaxRounds: 0,
        fastBrushThreads: 10, // 每会话请求数上限 (probe11: 每会话 10 请求 × 4s = 40s 预算内)
        fastBrushWafBackoff: 120,
        fastBrushEventsPerRequest: kFast2EventsPerRequest,
        fastBrushStayTime: 10000,
        fastBrushPollInterval: 10,
        speed: 2.0,
        heartbeatInterval: kFast2HeartbeatInterval,
        completionThreshold: kFast2CompletionThreshold,
        progressPollInterval: kFast2ProgressPollInterval, // 35s, ≥延迟入账30s
        parallelExecution: true,
        parallelTaskCount: 100,
      );
    case ReportMode.fast3:
      // 快刷模式3 (round15 多账户批量注入): 多操作者集群每轮 barrier 并发
      // 注入受害目标 (= 当前登录账号) 的课时, 轮间等 pti 窗口滚动, 达标即停。
      return const ReportConfig(
        fastBrush: true,
        fastBrush3: true,
        fastBrushMaxRounds: 0,
        fastBrushStayTime: 10000,
        fastBrushEventsPerRequest: 1,
        speed: kFast3Speed,
        fast3RoundGap: kFast3RoundGap,
        completionThreshold: kFast3CompletionThreshold,
        realProgressQuery: true,
        progressPollInterval: 35,
      );
    case ReportMode.rebrush:
      // 重刷模式 (基于普通模式): 行为链与普通模式完全一致 (单发心跳 / 1x 倍速 /
      // 心跳 60s), 差异仅在结束条件 — 每课固定 rebrushRounds 轮,
      // 每轮目标 = 服务器已刷时长 + rebrushExtraMinutes 分钟, 跑满轮数即止
      return const ReportConfig(
        rebrush: true,
        rebrushRounds: 1,
        rebrushExtraMinutes: 60,
      );
    case ReportMode.compensate:
      return const ReportConfig(compensate: true);
    case ReportMode.custom:
      // 默认配置与普通模式完全相同 (仅启用自定义脚本):
      // 心跳 60s / 倍速 1x / 阈值 0.8 / 真实进度查询等均沿用默认, 全部由脚本控制。
      // customScript 默认留空, 由 [_loadExampleScript] 从 assets 异步填充。
      return const ReportConfig(customEnabled: true);
  }
}

/// 课程类型选项 (对齐 EWT Web 1225.80da63bc56.js)
const _courseTypes = <(String, int?)>[
  ('全部', null),
  ('视频', 1),
  ('试卷', 2),
  ('FM', 3),
  ('资讯', 4),
  ('板报', 5),
  ('测评', 6),
  ('课后习题', 7),
  ('校本视频', 11),
  ('校本试卷', 12),
  ('模拟选科', 13),
  ('B端测评', 14),
  ('专题', 15),
  ('课程包', 16),
  ('直播', 17),
  ('选科测评', 18),
  ('专题', 19),
  ('学科专项', 20),
  ('模拟选科决策分析', 21),
];

/// 默认勾选的课程类型
///
/// 对齐 Python: 默认勾选"视频 / FM / 校本视频"
const _defaultTypes = <int?>[1, 3, 11];

/// 学科本地列表 (备用, 对齐 getStudentHomeworkDaySubjectStat 接口实际返回)
///
/// subjectId 10/11/12 的实际名称为 "心灵成长"/"生涯规划"/"综合素养",
/// 而非早期 Web JS 中的简称 "心理"/"生涯"/"素养"。
const _localSubjects = [
  '语文', '数学', '英语', '物理', '化学', '生物',
  '政治', '历史', '地理', '心灵成长', '生涯规划', '综合素养',
  '信息', '通用', '科学',
];

/// 倍速选项
const _speedOptions = [0.8, 1.0, 1.2, 1.5, 2.0];

/// 进度上报配置页 (独立页面, 非弹窗)
///
/// 替代原 [ReportConfigDialog], 对应 Python: gui/dialogs/report_config.py
/// ReportConfigDialog。
///
/// 支持 6 种模式快捷切换 (正常 / 快刷 / 快刷2 / 重刷 / 补偿检测 / 自定义),
/// 每种模式拥有独立配置与独立持久化存储; 当前选中的模式也会被记录,
/// 下次打开直接使用。
///
/// 响应式布局 (提升空间利用率):
/// - 宽屏 (expanded+): 左栏 上报模式+课程筛选, 右栏 上报参数;
///   自定义模式下右栏为撑满整页高度的 QuickJS 脚本编辑器
/// - 窄屏: 单列滚动
///
/// "任意用户进度注入"分区的显示由设置页高级栏的显示开关控制
/// (settings.showReportInject, 默认隐藏)。
class ReportConfigPage extends ConsumerStatefulWidget {
  /// 动态学科列表 (优先使用, 为 null 时回退到本地列表 [_localSubjects])
  final List<String>? subjects;

  const ReportConfigPage({super.key, this.subjects});

  /// 打开配置页面，返回用户配置（取消返回 null）
  ///
  /// [subjects] 动态学科列表 (来自 getStudentHomeworkDaySubjectStat),
  /// 为 null 时使用本地列表。优先动态加载, 失败回退本地列表。
  ///
  /// 页面 push 到 root navigator (与原 showDialog 的 useRootNavigator 行为
  /// 一致): 从 ShellRoute 内层页面 (作业/周培优) 打开时覆盖整个窗口,
  /// 不被侧栏/底部导航遮挡。
  static Future<ReportConfig?> show(
    BuildContext context, {
    List<String>? subjects,
  }) {
    return Navigator.of(context, rootNavigator: true).push<ReportConfig>(
      MaterialPageRoute(builder: (_) => ReportConfigPage(subjects: subjects)),
    );
  }

  @override
  ConsumerState<ReportConfigPage> createState() => _ReportConfigPageState();
}

class _ReportConfigPageState extends ConsumerState<ReportConfigPage> {
  /// 实际使用的学科列表 (动态优先, 失败回退本地)
  List<String> get _subjects => widget.subjects ?? _localSubjects;

  ReportMode _activeMode = ReportMode.normal;

  /// 各模式独立配置 (内存中随时同步, 确认时整体落盘)
  final Map<ReportMode, ReportConfig> _configs = {};

  bool _filterCompleted = true;
  bool _filterSeriousCheckChecked = false;
  final Set<int?> _selectedTypes = {..._defaultTypes};
  late final Set<String> _selectedSubjects;
  int _heartbeatInterval = 60;
  double _speed = 1.0;
  bool _useBackup = false;
  String _reportBackend = 'clog';
  int _maxRounds = 0;
  int _fastBrushThreads = 10;
  // 快刷模式2 每轮铸造 session 数 (多 session 预算乘法)
  int _fastBrushSessions = 8;

  // 快刷模式3: 轮间等待秒数 + 操作者账号 (userId 集合)
  int _fast3RoundGap = kFast3RoundGap;
  Set<String> _operatorUserIds = {};

  // 快刷 WAF 限流退避 (ms): 并发 collect 全部失败时指数退避基数
  int _fastBrushWafBackoff = 120;
  // 快刷每请求事件数 (0=自动): 每个请求 EventPackage 打包的事件数
  // 0 = 使用服务端 getPlayerGlobalConf.maxBatchSize, 对齐 Python EVENTS_PER_REQUEST/_resolve_multi
  int _fastBrushEventsPerRequest = 0;

  // 重刷模式(刷时长): 每课固定轮数, 每轮目标 = 已刷时长 + 额外分钟
  int _rebrushRounds = 1;
  int _rebrushExtraMinutes = 40;

  // 是否从上次进度开始 (默认 true)
  // 开启时: 真实播放 seek 到 playTime; 进度上报 首轮即从 finishPlayTime 续刷
  bool _resumeFromServer = true;

  // 真实进度查询 (默认 true)
  // 开启时: 到达完成阈值自动跳到下一个任务 (普通模式和快刷模式都可用)
  // 关闭时: 使用本地模拟进度
  bool _realProgressQuery = true;

  // 真实进度轮询间隔 (秒, 默认 60)
  // 控制弹窗 UI 进度栏和引擎内部查询服务端真实进度的频率
  int _progressPollInterval = 60;

  // 并行执行模式 (默认 false)
  // 开启时: 按并行任务数并发执行多个任务
  bool _parallelExecution = false;
  int _parallelTaskCount = 2;

  // 完成阈值 (0.8=80%, 0.85=85%, 1.0=100%, 自定义=用户输入)
  double _completionThreshold = 0.8;
  bool _customThreshold = false;
  final _customThresholdController = TextEditingController();

  // 自定义模式 (QuickJS) 脚本 (CodeController 支持 JS 语法高亮)
  final CodeController _customScriptController =
      CodeController(language: javascript);

  // V7 任意用户进度注入: 覆盖 CommonPackage.userid, 进度写入目标用户
  bool _injectUserId = false;
  String _injectTargetUserId = '';
  final _injectUserIdController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedSubjects = {..._subjects};
    _customThresholdController.text =
        '${(_completionThreshold * 100).round()}';
    // 先用默认配置填充, 避免首帧访问空 map; 随后异步加载已保存配置覆盖
    for (final m in ReportMode.values) {
      _configs[m] = _defaultConfigForMode(m);
    }
    _loadSaved();
  }

  /// 从 shared_preferences 加载已保存的模式选择与各模式独立配置
  ///
  /// 异步执行 (SharedPreferences 为异步 API), 加载完成前保持默认配置,
  /// 加载完成后通过 setState 覆盖各字段。快刷模式若无已保存值, 则保持
  /// 对齐 ewt360_lite_client 的默认配置。
  Future<void> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeStr = prefs.getString(_kReportModeKey);
      _activeMode = _modeKeys.entries
          .where((e) => e.value == modeStr)
          .map((e) => e.key)
          .firstOrNull ?? ReportMode.normal;

      for (final m in ReportMode.values) {
        final raw = prefs.getString('$_kReportConfigPrefix${_modeKeys[m]}');
        if (raw != null && raw.isNotEmpty) {
          try {
            _configs[m] = ReportConfig.fromJson(jsonDecode(raw));
            continue;
          } catch (_) {
            // 解析失败: 回退默认
          }
        }
        _configs[m] = _defaultConfigForMode(m);
      }
    } catch (_) {
      for (final m in ReportMode.values) {
        _configs[m] = _defaultConfigForMode(m);
      }
    }
    if (mounted) _loadIntoFields(_configs[_activeMode]!);
    // 自定义模式: 若未保存过脚本 (空), 用 assets 示例脚本填充默认
    _ensureCustomDefaultScript();
  }

  /// 自定义模式脚本默认值: 未保存过脚本时用 assets 示例脚本填充
  ///
  /// 仅当 [ReportConfig.customScript] 为空时生效 (用户已保存的脚本不覆盖)。
  /// 加载失败 (资源缺失) 时保持空, 用户可点「示例脚本」重试。
  Future<void> _ensureCustomDefaultScript() async {
    final cfg = _configs[ReportMode.custom];
    if (cfg == null || cfg.customScript.trim().isNotEmpty) return;
    final script = await _loadExampleScript();
    if (script.isEmpty) return;
    _configs[ReportMode.custom] = ReportConfig(
      customEnabled: true,
      customScript: script,
    );
    if (mounted && _activeMode == ReportMode.custom) {
      _loadIntoFields(_configs[ReportMode.custom]!);
    }
  }

  /// 将指定模式的配置应用到表单字段 (仅覆盖字段值, 不触发 setState 之外的副作用)
  void _loadIntoFields(ReportConfig c) {
    setState(() {
      _filterCompleted = c.filterCompleted;
      _filterSeriousCheckChecked = c.filterSeriousCheckChecked;
      _selectedTypes
        ..clear()
        ..addAll(c.selectedTypes.isEmpty ? const [null] : c.selectedTypes);
      // 学科: 保留已保存学科 (即使不在当前动态列表中, 避免动态列表变化丢配置)
      _selectedSubjects
        ..clear()
        ..addAll(c.selectedSubjects.isEmpty ? _subjects : c.selectedSubjects);
      _heartbeatInterval = c.heartbeatInterval;
      _speed = c.speed;
      _useBackup = c.useBackup;
      _reportBackend = c.reportBackend;
      _maxRounds = c.fastBrushMaxRounds;
      _fastBrushThreads = c.fastBrushThreads;
      _fastBrushSessions = c.fastBrushSessions;
      _fastBrushWafBackoff = c.fastBrushWafBackoff;
      _fastBrushEventsPerRequest = c.fastBrushEventsPerRequest;
      _fast3RoundGap = c.fast3RoundGap;
      _operatorUserIds = {...c.operatorUserIds};
      _rebrushRounds = c.rebrushRounds;
      _rebrushExtraMinutes = c.rebrushExtraMinutes;
      _resumeFromServer = c.resumeFromServer;
      _realProgressQuery = c.realProgressQuery;
      _progressPollInterval = c.progressPollInterval;
      _parallelExecution = c.parallelExecution;
      _parallelTaskCount = c.parallelTaskCount.clamp(1, 100);
      _completionThreshold = c.completionThreshold;
      _customScriptController.text = c.customScript;
      // V7 注入配置
      _injectUserId = c.injectUserId;
      _injectTargetUserId = c.injectTargetUserId;
      _injectUserIdController.text = c.injectTargetUserId;
      // 自定义阈值判定: 与预设值不同 → 视为自定义
      _customThreshold = !_thresholdPresets
          .any((p) => p.$2 == c.completionThreshold);
      _customThresholdController.text =
          '${(c.completionThreshold * 100).round()}';
    });
  }

  /// 将当前模式配置写回内存 map (表单 → ReportConfig)
  void _syncToActive() {
    _configs[_activeMode] = _buildConfig();
  }

  /// 保存当前所有模式配置 + 选中的模式到 shared_preferences
  /// (下次打开程序可直接使用上次选择的模式与其配置)
  Future<void> _saveCurrent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kReportModeKey, _modeKeys[_activeMode]!);
      for (final m in ReportMode.values) {
        await prefs.setString(
          '$_kReportConfigPrefix${_modeKeys[m]}',
          jsonEncode(_configs[m]!.toJson()),
        );
      }
    } catch (_) {
      // 持久化失败不影响本次使用
    }
  }

  /// 由当前表单字段构建当前模式的 [ReportConfig]
  ///
  /// fastBrush / rebrush / compensate 三个开关由当前选中的模式决定,
  /// 不再作为独立开关由用户勾选。
  ReportConfig _buildConfig() => ReportConfig(
        filterCompleted: _filterCompleted,
        filterSeriousCheckChecked: _filterSeriousCheckChecked,
        selectedTypes: _selectedTypes.toList(),
        selectedSubjects: _selectedSubjects.toList(),
        heartbeatInterval: _heartbeatInterval,
        speed: _speed,
        useBackup: _useBackup,
        reportBackend: _reportBackend,
        fastBrush: _activeMode == ReportMode.fast ||
            _activeMode == ReportMode.fast2 ||
            _activeMode == ReportMode.fast3,
        fastBrush2: _activeMode == ReportMode.fast2,
        fastBrush3: _activeMode == ReportMode.fast3,
        fast3RoundGap: _fast3RoundGap,
        operatorUserIds: _operatorUserIds.toList(),
        fastBrushSessions: _fastBrushSessions,
        fastBrushMaxRounds: _maxRounds,
        fastBrushThreads: _fastBrushThreads,
        fastBrushWafBackoff: _fastBrushWafBackoff,
        fastBrushEventsPerRequest: _fastBrushEventsPerRequest,
        rebrush: _activeMode == ReportMode.rebrush,
        rebrushRounds: _rebrushRounds,
        rebrushExtraMinutes: _rebrushExtraMinutes,
        compensate: _activeMode == ReportMode.compensate,
        completionThreshold: _completionThreshold,
        resumeFromServer: _resumeFromServer,
        realProgressQuery: _realProgressQuery,
        progressPollInterval: _progressPollInterval,
        parallelExecution: _parallelExecution,
        parallelTaskCount: _parallelTaskCount,
        customEnabled: _activeMode == ReportMode.custom,
        customScript: _customScriptController.text,
        injectUserId: _injectUserId,
        injectTargetUserId: _injectTargetUserId,
      );

  @override
  void dispose() {
    _customThresholdController.dispose();
    _customScriptController.dispose();
    _injectUserIdController.dispose();
    super.dispose();
  }

  /// 预设完成阈值选项
  static const _thresholdPresets = <(String, double)>[
    ('80%', 0.8),
    ('85%', 0.85),
    ('100%', 1.0),
  ];

  String get _modeDescription {
    switch (_activeMode) {
      case ReportMode.normal:
        return '正常模式: 标准播放心跳, 逐步上报进度';
      case ReportMode.fast:
        return '快刷模式: 并发 burst 快速刷进度';
      case ReportMode.fast2:
        return '快刷模式2: 多session预算乘法 (每轮铸造独立会话, 预算按会话独立核算, 信用随会话数近线性放大)';
      case ReportMode.fast3:
        return '快刷模式3: 多账户批量注入 — 从已保存账号选取操作者集群 (密码账号失效自动重登; '
            '短信/扫码账号 token 有效可选), '
            '并发向当前账号的课时注入进度, 受害者userid=当前账号 (不可编辑), token 失效自动重登';
      case ReportMode.rebrush:
        return '重刷模式: 基于普通模式行为链 (单发心跳), 每课固定轮数续刷时长, 跑满轮数即止';
      case ReportMode.compensate:
        return '补偿检测模式: 仅补偿认真度/互动点上报, 不刷进度';
      case ReportMode.custom:
        return '自定义模式: 使用 QuickJS 脚本编写上报逻辑 (可调用宿主函数/账号字段)';
    }
  }

  /// 是否处于自定义模式 (隐藏全部通用配置, 仅脚本编辑器生效)
  bool get _isCustomMode => _activeMode == ReportMode.custom;

  /// 是否显示快刷参数 (仅快刷模式 / 快刷模式2; 快刷模式3 使用独立参数区;
  /// 重刷模式已改为基于普通模式行为链, 单发心跳不再有 burst 并发参数)
  bool get _showFastBrushParams =>
      _activeMode == ReportMode.fast || _activeMode == ReportMode.fast2;

  /// 是否显示快刷3 参数区 (操作者账号 / 轮间等待)
  bool get _showFast3Params => _activeMode == ReportMode.fast3;

  void _selectThresholdPreset(double value) {
    setState(() {
      _completionThreshold = value;
      _customThreshold = false;
      _customThresholdController.text = '${(value * 100).round()}';
    });
  }

  void _selectCustomThreshold() {
    setState(() {
      _customThreshold = true;
      final n = int.tryParse(_customThresholdController.text);
      if (n != null && n >= 1 && n <= 100) {
        _completionThreshold = n / 100.0;
      }
    });
  }

  void _onCustomThresholdChanged(String v) {
    final n = int.tryParse(v);
    if (n != null && n >= 1 && n <= 100) {
      _completionThreshold = n / 100.0;
    }
  }

  void _onTypeChanged(int? ct, bool checked) {
    setState(() {
      if (ct == null && checked) {
        // 勾选"全部" → 取消其他
        _selectedTypes.clear();
        _selectedTypes.add(null);
      } else if (ct != null && checked) {
        // 勾选具体类型 → 取消"全部"
        _selectedTypes.remove(null);
        _selectedTypes.add(ct);
      } else {
        _selectedTypes.remove(ct);
      }
    });
  }

  void _onModeChanged(Set<ReportMode> selected) {
    final m = selected.first;
    if (m == _activeMode) return;
    // 先把当前表单字段同步回旧模式, 再切换到新模式并加载其配置
    _syncToActive();
    setState(() {
      _activeMode = m;
    });
    _loadIntoFields(_configs[_activeMode]!);
    // 切换到自定义模式: 若脚本为空, 用 assets 示例脚本填充
    if (m == ReportMode.custom) _ensureCustomDefaultScript();
  }

  /// 将当前模式配置恢复为默认值（速调表 [_defaultConfigForMode]）并应用到表单。
  ///
  /// 用于覆盖之前已保存的旧配置（如心跳 60s / 阈值 1.0 的旧快刷默认值）。
  /// 点「确认」后 [_saveCurrent] 会把新默认值写回，覆盖旧配置。
  void _resetCurrentToDefault() {
    _configs[_activeMode] = _defaultConfigForMode(_activeMode);
    _loadIntoFields(_configs[_activeMode]!);
    // 恢复默认后: 自定义模式脚本为空, 重新用 assets 示例脚本填充
    if (_activeMode == ReportMode.custom) _ensureCustomDefaultScript();
  }

  void _onConfirm() {
    // 注入: 开启时目标必须为纯数字 userid (CommonPackage.userid 为整型)
    if (_injectUserId && _injectTargetUserId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已开启任意用户进度注入, 请填写目标 userid'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // 快刷3: 必须先选取操作者账号 (受害者固定为当前登录账号)
    if (_activeMode == ReportMode.fast3 && _operatorUserIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('快刷模式3 需要至少选择一个操作者账号 '
              '(密码登录账号, 或 token 检测有效的短信/扫码账号)'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // 自定义模式: 过滤由脚本内自行处理, 跳过类型/学科必选校验
    if (!_isCustomMode) {
      if (_selectedTypes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请至少选择一个课程类型'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      if (_selectedSubjects.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请至少选择一个课程学科'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    }

    _syncToActive();
    final config = _configs[_activeMode];
    Navigator.of(context).pop(config);
    // 持久化保存 (不 await: 页面已关闭, 写入异步完成即可)
    _saveCurrent();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回 (不保存)',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('进度上报配置'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('恢复默认'),
            onPressed: _resetCurrentToDefault,
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('确认'),
            onPressed: _onConfirm,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= AppBreakpoints.expanded;
          if (!isWide) return _buildNarrowBody(theme);
          return _buildWideBody(theme);
        },
      ),
    );
  }

  // ─── 布局 ───

  /// 窄屏: 单列滚动 (模式 → 编辑器/筛选 → 参数)
  Widget _buildNarrowBody(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildModeSection(theme),
          if (_isCustomMode) ...[
            const SizedBox(height: 12),
            _buildScriptEditor(theme, fillsHeight: false),
          ] else ...[
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            _buildFilterSection(theme),
            const SizedBox(height: 8),
            _buildGeneralParamsSection(theme),
            if (_showFastBrushParams) ...[
              const SizedBox(height: 8),
              _buildFastBrushSection(theme),
            ],
            if (_showFast3Params) ...[
              const SizedBox(height: 8),
              _buildFast3Section(theme),
            ],
            if (_activeMode == ReportMode.rebrush) ...[
              const SizedBox(height: 8),
              _buildRebrushSection(theme),
            ],
            const SizedBox(height: 8),
            _buildParallelSection(theme),
          ],
        ],
      ),
    );
  }

  /// 宽屏: 双栏 (左 模式+课程筛选 | 右 参数 或 全高脚本编辑器)
  Widget _buildWideBody(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左栏: 上报模式 + 课程筛选 (自定义模式无课程筛选)
        SizedBox(
          width: 380,
          child: Container(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: theme.dividerColor)),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildModeSection(theme),
                  if (!_isCustomMode) ...[
                    const SizedBox(height: 12),
                    const Divider(),
                    const SizedBox(height: 8),
                    _buildFilterSection(theme),
                  ],
                ],
              ),
            ),
          ),
        ),
        // 右栏: 上报参数 (自定义模式为撑满高度的脚本编辑器)
        Expanded(
          child: _isCustomMode
              ? _buildScriptEditor(theme, fillsHeight: true)
              : Scrollbar(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildGeneralParamsSection(theme),
                        if (_showFastBrushParams) ...[
                          const SizedBox(height: 8),
                          _buildFastBrushSection(theme),
                        ],
                        if (_showFast3Params) ...[
                          const SizedBox(height: 8),
                          _buildFast3Section(theme),
                        ],
                        if (_activeMode == ReportMode.rebrush) ...[
                          const SizedBox(height: 8),
                          _buildRebrushSection(theme),
                        ],
                        const SizedBox(height: 8),
                        _buildParallelSection(theme),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  // ─── 配置分区 ───

  /// 上报模式 (下拉 + 模式说明)
  Widget _buildModeSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('上报模式',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
        const SizedBox(height: 4),
        // key: ValueKey(_activeMode) → 模式切换后重建, 使 initialSelection 同步显示
        DropdownMenu<ReportMode>(
          key: ValueKey(_activeMode),
          initialSelection: _activeMode,
          label: const Text('上报模式'),
          expandedInsets: EdgeInsets.zero,
          textStyle: theme.textTheme.bodyMedium,
          menuStyle: MenuStyle(
            visualDensity: VisualDensity.comfortable,
            maximumSize: const WidgetStatePropertyAll<Size?>(
                Size(320, 320)),
          ),
          dropdownMenuEntries: ReportMode.values
              .map((m) => DropdownMenuEntry<ReportMode>(
                    value: m,
                    label: _modeLabels[m]!,
                  ))
              .toList(),
          onSelected: (m) {
            if (m == null) return;
            _onModeChanged({m});
          },
        ),
        const SizedBox(height: 4),
        Text(_modeDescription,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
      ],
    );
  }

  /// 任意用户进度注入 (覆盖 CommonPackage.userid)
  ///
  /// 位于通用参数开关区末尾 (自定义模式隐藏通用参数区, 由脚本自行处理上报身份)。
  Widget _buildInjectSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('任意用户进度注入',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text(
                      '覆盖 CommonPackage.userid, 进度写入目标用户而非当前账号 (token 仅认证)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            Switch(
              value: _injectUserId,
              onChanged: (v) => setState(() => _injectUserId = v),
            ),
          ],
        ),
        if (_injectUserId) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('目标 userid',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
              ),
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _injectUserIdController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '纯数字 userid',
                  ),
                  onChanged: (v) => _injectTargetUserId = v.trim(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('注意: 真实进度轮询仍查询当前账号, 与目标用户的进度无关',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              )),
        ],
      ],
    );
  }

  /// 课程类型 / 学科过滤
  Widget _buildFilterSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('上报课程类型（至少选择一项）',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          children: _courseTypes.map((entry) {
            final (name, ct) = entry;
            return FilterChip(
              label: Text(name),
              selected: _selectedTypes.contains(ct),
              onSelected: (checked) => _onTypeChanged(ct, checked),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        Text('上报课程学科（至少选择一项）',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 2,
          children: _subjects.map((name) {
            return FilterChip(
              label: Text(name),
              selected: _selectedSubjects.contains(name),
              onSelected: (checked) {
                setState(() {
                  if (checked) {
                    _selectedSubjects.add(name);
                  } else {
                    _selectedSubjects.remove(name);
                  }
                });
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  /// 自定义模式: QuickJS 脚本编辑器
  ///
  /// [fillsHeight] 宽屏布局下撑满剩余高度 (expands), 窄屏使用固定行数随页面滚动。
  Widget _buildScriptEditor(ThemeData theme, {required bool fillsHeight}) {
    final editor = CodeTheme(
      data: CodeThemeData(styles: _kJetBrainsCodeStyles),
      child: CodeField(
        controller: _customScriptController,
        expands: fillsHeight,
        minLines: fillsHeight ? null : 16,
        maxLines: fillsHeight ? null : 28,
        wrap: true,
        background: const Color(0xFF2B2B2B), // JetBrains Darcula 背景
        textStyle: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: Color(0xFFA9B7C6),
        ),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF3C3F41)),
          borderRadius: BorderRadius.circular(4),
        ),
        onChanged: (_) {}, // 由 controller 直接持有
      ),
    );

    final toolbar = Row(
      children: [
        Expanded(
          child: Text('QuickJS 上报脚本 (async function main)',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              )),
        ),
        TextButton.icon(
          onPressed: () async {
            final script = await _loadExampleScript();
            if (!mounted) return;
            if (script.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('示例脚本资源加载失败'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            } else {
              setState(() {
                _customScriptController.text = script;
              });
            }
          },
          icon: const Icon(Icons.auto_awesome, size: 14),
          label: const Text('示例脚本'),
        ),
        TextButton.icon(
          onPressed: () {
            setState(() {
              _customScriptController.clear();
            });
          },
          icon: const Icon(Icons.cleaning_services_outlined, size: 14),
          label: const Text('清空'),
        ),
      ],
    );

    if (!fillsHeight) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          toolbar,
          const SizedBox(height: 4),
          editor,
          const SizedBox(height: 4),
        ],
      );
    }

    // 宽屏: 编辑器撑满右栏剩余高度
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toolbar,
          const SizedBox(height: 4),
          Expanded(child: editor),
        ],
      ),
    );
  }

  /// 通用上报参数 (心跳/倍速/阈值/进度查询/跳过/续刷/备用通道)
  Widget _buildGeneralParamsSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ─── 心跳时间 ───
        Row(
          children: [
            Expanded(
              child: Text('心跳时间（秒）',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
            SizedBox(
              width: 100,
              child: TextField(
                controller: TextEditingController(
                    text: '$_heartbeatInterval'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 1 && n <= 600) {
                    _heartbeatInterval = n;
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ─── 倍速 ───
        Row(
          children: [
            Expanded(
              child: Text('上报倍速',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
            SizedBox(
              width: 100,
              child: DropdownButtonFormField<double>(
                initialValue: _speed,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: _speedOptions
                    .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text('${s}x'),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _speed = v);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ─── 完成阈值 ───
        Text('完成阈值',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          children: [
            ..._thresholdPresets.map((entry) {
              final (label, value) = entry;
              return ChoiceChip(
                label: Text(label),
                selected:
                    !_customThreshold && _completionThreshold == value,
                onSelected: (_) => _selectThresholdPreset(value),
              );
            }),
            ChoiceChip(
              label: const Text('自定义'),
              selected: _customThreshold,
              onSelected: (_) => _selectCustomThreshold(),
            ),
          ],
        ),
        if (_customThreshold) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: 120,
            child: TextField(
              controller: _customThresholdController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                suffixText: '%',
                hintText: '1-100',
              ),
              onChanged: _onCustomThresholdChanged,
            ),
          ),
          const SizedBox(height: 4),
        ],
        const SizedBox(height: 12),

        // ─── 真实进度查询 ───
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('真实进度查询',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text('到达完成阈值自动跳到下一个任务，关闭则使用本地进度',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            Switch(
              value: _realProgressQuery,
              onChanged: (v) =>
                  setState(() => _realProgressQuery = v),
            ),
          ],
        ),
        if (_realProgressQuery) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text('轮询间隔（秒，默认60）',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: TextEditingController(
                        text: '$_progressPollInterval'),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n >= 5 && n <= 600) {
                        _progressPollInterval = n;
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),

        // ─── 跳过已观看完的课程 ───
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('跳过已观看完的课程',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text('taskStatus == 30 (已观看完成)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            Switch(
              value: _filterCompleted,
              onChanged: (v) =>
                  setState(() => _filterCompleted = v),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ─── 跳过已完成认真度检测课程 ───
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('跳过已完成认真度检测课程',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text('seriousCheckResult == 2 (已通过)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            Switch(
              value: _filterSeriousCheckChecked,
              onChanged: (v) =>
                  setState(() => _filterSeriousCheckChecked = v),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ─── 从上次进度开始 ───
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('从上次进度开始',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text('播放和进度上报从服务端 finishPlayTime 处继续',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            Switch(
              value: _resumeFromServer,
              onChanged: (v) =>
                  setState(() => _resumeFromServer = v),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ─── 备用上报通道 ───
        Row(
          children: [
            Expanded(
              child: Text('使用备用上报通道（CLOG/DLOG/IPLOG）',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
            Switch(
              value: _useBackup,
              onChanged: (v) => setState(() => _useBackup = v),
            ),
          ],
        ),
        if (_useBackup) ...[
          Row(
            children: [
              Expanded(
                child: Text('上报通道',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
              ),
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<String>(
                  initialValue: _reportBackend,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'clog', child: Text('CLOG')),
                    DropdownMenuItem(value: 'dlog', child: Text('DLOG')),
                    DropdownMenuItem(
                        value: 'iplog', child: Text('IPLOG')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _reportBackend = v);
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],

        const SizedBox(height: 12),

        // ─── 任意用户进度注入 (设置页高级栏"任意用户进度注入"控制显示) ───
        // 快刷3 受害者固定为当前登录账号, 不提供 userid 覆盖
        if (ref.watch(appSettingsProvider).showReportInject &&
            _activeMode != ReportMode.fast3)
          _buildInjectSection(theme),
      ],
    );
  }

  /// 快刷3 参数 (仅快刷模式3): 操作者账号选取 / 受害者说明 / 轮间等待
  Widget _buildFast3Section(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Text('快刷3 参数（多账户批量注入）',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            )),
        const SizedBox(height: 8),
        // 受害者说明 (当前账号, 不可编辑)
        Row(
          children: [
            Expanded(
              child: Text('受害者 userid',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
            Text('当前登录账号 (不可编辑)',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                )),
          ],
        ),
        const SizedBox(height: 8),
        // 操作者账号选取
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('操作者账号（已选 ${_operatorUserIds.length} 个）',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text('弹窗多选: 密码账号失效自动重登; 短信/扫码账号 token 有效可选',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: _pickOperators,
              icon: const Icon(Icons.group_add, size: 18),
              label: const Text('选择账号'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 轮间等待
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('轮间等待（秒, 5~600）',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text('等 pti 窗口滚动后进入下一轮 (对齐 ROUND_GAP=45)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            SizedBox(
              width: 100,
              child: TextField(
                controller: TextEditingController(text: '$_fast3RoundGap'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 5 && n <= 600) {
                    _fast3RoundGap = n;
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('每轮每操作者 1 包并发注入 (端点轮换 bfe/clog/dlog), '
            '单包 stay=10s / speed=2.0; 每轮观测 15s 后查真实进度, 达标即停',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            )),
      ],
    );
  }

  /// 打开操作者账号选取弹窗 (多选: 密码账号 / token 有效的短信扫码账号)
  Future<void> _pickOperators() async {
    _syncToActive(); // 保存当前表单, 避免弹窗返回后被覆盖
    final picked = await OperatorAccountPickerDialog.show(
      context,
      initialUserIds: _operatorUserIds,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _operatorUserIds = picked.map((a) => a.userId).toSet();
    });
  }

  /// 快刷参数 (快刷模式 / 快刷模式2 均生效)
  Widget _buildFastBrushSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Text('快刷参数',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            )),
        const SizedBox(height: 8),
        // 最大重刷轮数
        Row(
          children: [
            Expanded(
              child: Text('最大重刷轮数（0=自动, 刷到达标为止）',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
            SizedBox(
              width: 100,
              child: TextField(
                controller: TextEditingController(text: '$_maxRounds'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 0 && n <= 50) {
                    _maxRounds = n;
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 并发线程数 (静态 burst)
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('并发线程数（静态 burst）',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text(
                      _activeMode == ReportMode.fast2
                          ? '快刷2: 每会话单轮请求数上限 (实际按 ~40s 会话预算自动收缩)'
                          : '可设为 1 = 单线程慢刷；与每请求事件数独立',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            SizedBox(
              width: 100,
              child: TextField(
                controller:
                    TextEditingController(text: '$_fastBrushThreads'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 1 && n <= 50) {
                    _fastBrushThreads = n;
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // session 数 (仅快刷模式2: 多 session 预算乘法)
        if (_activeMode == ReportMode.fast2)
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('session 数（多会话预算乘法）',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                    Text('每轮铸造 N 个独立会话, 总信用 ≈ N × ~40s',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                  ],
                ),
              ),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: TextEditingController(
                      text: '$_fastBrushSessions'),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 1 && n <= 50) {
                      _fastBrushSessions = n;
                    }
                  },
                ),
              ),
            ],
          ),
        const SizedBox(height: 8),
        // WAF 限流退避 (ms)
        Row(
          children: [
            Expanded(
              child: Text('WAF 限流退避（ms, 0~10000）',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
            SizedBox(
              width: 100,
              child: TextField(
                controller: TextEditingController(
                    text: '$_fastBrushWafBackoff'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 0 && n <= 10000) {
                    _fastBrushWafBackoff = n;
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 每请求事件数 (EventPackage 打包数)
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('每请求事件数（0=自动, 1~200）',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text('每个请求 EventPackage 打包事件数；0=用服务端 maxBatchSize',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            SizedBox(
              width: 100,
              child: TextField(
                controller: TextEditingController(
                    text: '$_fastBrushEventsPerRequest'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 0 && n <= 200) {
                    _fastBrushEventsPerRequest = n;
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 重刷参数 (仅重刷模式)
  Widget _buildRebrushSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Text('重刷参数（刷时长）',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            )),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text('重刷轮数 (每课最大轮数)',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
            SizedBox(
              width: 100,
              child: TextField(
                controller: TextEditingController(text: '$_rebrushRounds'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 1 && n <= 1000) {
                    _rebrushRounds = n;
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text('每轮额外时长 (分钟, 默认40)',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            ),
            SizedBox(
              width: 100,
              child: TextField(
                controller:
                    TextEditingController(text: '$_rebrushExtraMinutes'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null && n >= 0 && n <= 100000) {
                    _rebrushExtraMinutes = n;
                  }
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 并行执行模式
  Widget _buildParallelSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('并行执行模式',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                  Text('多个任务并发执行，可设置 1~100 个任务并行',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      )),
                ],
              ),
            ),
            Switch(
              value: _parallelExecution,
              onChanged: (v) =>
                  setState(() => _parallelExecution = v),
            ),
          ],
        ),
        if (_parallelExecution) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('并行任务数',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
              ),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: TextEditingController(
                      text: '$_parallelTaskCount'),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '1-100',
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 1 && n <= 100) {
                      _parallelTaskCount = n;
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
