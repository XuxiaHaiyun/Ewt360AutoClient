/// 批量任务进度上报执行弹窗：以进度/日志/详情三标签页展示任务执行状态、
/// 详细日志与 BFE 会话上下文，支持按间隔轮询服务端真实进度并显示任务耗时。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/serious_check_config.dart';
import '../../domain/entities/video_session.dart';

/// 单条任务的执行状态
class TaskProgressItem {
  final String title;
  final String subtitle;
  PlaybackState state;
  double progress; // 0.0 ~ 1.0
  String? message;
  String? error;

  /// 任务开始时间 (首次进入非初始化/非终态时由弹窗记录)
  ///
  /// 用于进度标签页已完成任务下方显示"耗时：xx时xx分xx秒"。
  /// 为可变字段 (与 [state]/[progress] 一致), 由弹窗在状态切换时就地填写,
  /// 可跨"后台执行→恢复弹窗"持久化 (items 列表由调用方持有, 不随弹窗重建丢失)。
  DateTime? startedAt;

  /// 任务结束时间 (进入完成/失败终态时由弹窗记录)
  DateTime? completedAt;

  TaskProgressItem({
    required this.title,
    this.subtitle = '',
    this.state = PlaybackState.initializing,
    this.progress = 0.0,
    this.message,
    this.error,
    this.startedAt,
    this.completedAt,
  });
}

/// 进度上报执行弹窗
///
/// 显示批量任务的执行进度、日志和停止按钮
/// 对应 Python: gui/dialogs/batch_progress.py BatchProgressDialog
///
/// 三标签页设计 (对齐用户要求: "上下文标签页(进度/日志/详情)"):
/// - 进度: 任务列表 + 总进度条 + 真实进度轮询
/// - 日志: 详细日志 (容量 2000 条) + 级别筛选 + 复制
/// - 详情: BFE 会话上下文 + 引擎实时状态 (时间偏移/检测点/黑名单/认真度配置)
class TaskProgressDialog extends StatefulWidget {
  final List<TaskProgressItem> items;
  final Stream<ProgressLogEvent> logStream;
  final VoidCallback onStop;

  /// 弹窗标题 (默认"进度上报")
  final String title;

  /// 真实进度轮询回调 (返回 {item index: ratio 0~1})
  ///
  /// 提供时, 弹窗按 [progressPollInterval] 秒间隔调用, 用服务端真实上报进度覆盖本地模拟进度。
  /// ratio >= [completionThreshold] 时显示为 100% 并标记任务完成。
  /// 不提供时, 使用引擎本地模拟进度 (playedSeconds/totalSeconds)。
  final Future<Map<int, double>> Function()? progressPoller;

  /// 真实进度轮询间隔 (秒, 默认 60)
  final int progressPollInterval;

  /// 真实进度完成阈值 (默认 0.8 = 80%), 达到即视为完成显示 100%
  final double completionThreshold;

  /// BFE 会话上下文流 (可选, 来自 [ProgressReportService.sessionStream])
  ///
  /// 提供时, "详情"标签页显示 sessionId/secret/clientIp/用户身份等。
  final Stream<SessionContext>? sessionStream;

  /// 引擎实时状态快照流 (可选, 来自 [ProgressReportService.engineStateStream])
  ///
  /// 提供时, "详情"标签页显示时间偏移/检测点/黑名单/认真度配置/心跳计数等。
  final Stream<EngineStateSnapshot>? engineStateStream;

  /// 点击"后台执行"时的回调 (由 [_TaskDialogManager] 注入)
  ///
  /// 提供时, actions 左侧显示"后台执行"按钮, 点击后隐藏弹窗并显示浮窗。
  final VoidCallback? onBackground;

  /// 任务全部完成时的回调 (由 [_TaskDialogManager] 注入, 用于记录完成状态)
  ///
  /// 重建弹窗时通过 [initialFinished] 恢复, 避免完成后按钮变回"停止"。
  final VoidCallback? onFinished;

  /// 初始完成状态 (重建弹窗时恢复, 避免状态丢失)
  final bool initialFinished;

  /// 初始 BFE 会话上下文 (后台执行恢复时, 从缓存恢复, 避免详情栏空白)
  final SessionContext? initialSession;

  /// 初始引擎实时状态快照 (后台执行恢复时, 从缓存恢复)
  final EngineStateSnapshot? initialEngineState;

  /// 初始引擎实时状态快照集 (并行模式: 多个任务各自的快照, key=taskIndex)
  ///
  /// 与 [initialEngineState] 并存: 提供时以本参数为准 (并行场景),
  /// 否则回退使用 [initialEngineState]。
  final Map<int, EngineStateSnapshot>? initialEngineStates;

  const TaskProgressDialog({
    super.key,
    required this.items,
    required this.logStream,
    required this.onStop,
    this.title = '进度上报',
    this.progressPoller,
    this.progressPollInterval = 60,
    this.completionThreshold = 0.8,
    this.sessionStream,
    this.engineStateStream,
    this.onBackground,
    this.onFinished,
    this.initialFinished = false,
    this.initialSession,
    this.initialEngineState,
    this.initialEngineStates,
  });

  /// 显示进度弹窗（barrierDismissible=false，必须通过停止/关闭按钮关闭）
  ///
  /// 默认支持"后台执行": 点击弹窗左下角"后台执行"按钮后, 弹窗隐藏为浮窗,
  /// 点击浮窗可恢复弹窗。设置 [allowBackground]=false 可禁用此功能。
  static Future<void> show(
    BuildContext context, {
    required List<TaskProgressItem> items,
    required Stream<ProgressLogEvent> logStream,
    required VoidCallback onStop,
    String title = '进度上报',
    GlobalKey<TaskProgressDialogState>? dialogKey,
    Future<Map<int, double>> Function()? progressPoller,
    int progressPollInterval = 60,
    double completionThreshold = 0.8,
    Stream<SessionContext>? sessionStream,
    Stream<EngineStateSnapshot>? engineStateStream,
    bool allowBackground = true,
  }) {
    if (!allowBackground) {
      return showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => TaskProgressDialog(
          key: dialogKey,
          items: items,
          logStream: logStream,
          onStop: onStop,
          title: title,
          progressPoller: progressPoller,
          progressPollInterval: progressPollInterval,
          completionThreshold: completionThreshold,
          sessionStream: sessionStream,
          engineStateStream: engineStateStream,
        ),
      );
    }
    // 使用 manager 管理弹窗/浮窗切换, 支持多个任务同时后台执行
    final manager = _TaskDialogManager(
      context: context,
      items: items,
      logStream: logStream,
      onStop: onStop,
      title: title,
      dialogKey: dialogKey,
      progressPoller: progressPoller,
      progressPollInterval: progressPollInterval,
      completionThreshold: completionThreshold,
      sessionStream: sessionStream,
      engineStateStream: engineStateStream,
    );
    return manager.show();
  }

  @override
  State<TaskProgressDialog> createState() => TaskProgressDialogState();
}

/// 日志事件
class ProgressLogEvent {
  final String message;
  final LogLevel level;
  final DateTime timestamp;

  /// 产生该日志的账号 token (批量任务按账号筛选日志用)
  ///
  /// null 表示全局日志 (如"开始批量任务"等不属于某个账号的记录)。
  final String? accountToken;

  ProgressLogEvent(
    this.message, {
    this.level = LogLevel.info,
    this.accountToken,
  }) : timestamp = DateTime.now();
}

/// 日志级别 (debug=最详细, error=最严重)
enum LogLevel {
  /// 调试细节 (过滤明细/心跳参数等)
  debug,
  /// 常规信息
  info,
  /// 成功
  success,
  /// 警告
  warning,
  /// 错误
  error,
}

class TaskProgressDialogState extends State<TaskProgressDialog> {
  static const int _maxLogs = 2000; // 日志容量上限 (对齐用户要求: 2000 条)

  final ScrollController _logScrollController = ScrollController();
  final List<ProgressLogEvent> _logs = [];
  StreamSubscription<ProgressLogEvent>? _logSubscription;
  bool _finished = false;

  // 真实进度轮询状态 (progressPoller 提供时启用)
  Timer? _pollTimer;
  final Map<int, double> _realProgress = {}; // index → ratio (0~1)
  final Set<int> _pollCompleted = {}; // 真实进度已达阈值的 item index
  bool _polling = false;

  // 当前标签页 (0=进度, 1=日志, 2=详情)
  int _tabIndex = 0;

  // 日志级别筛选 (null=全部)
  LogLevel? _logFilter;

  // BFE 会话上下文 (来自 sessionStream, 初始值从 widget.initialSession 恢复)
  SessionContext? _session;
  StreamSubscription<SessionContext>? _sessionSub;

  // 引擎实时状态快照集 (来自 engineStateStream, key=taskIndex)
  //
  // 并行执行模式下多个引擎并发 emit, 每个任务一个快照,
  // 详情栏按任务索引展示所有执行中任务的状态, 而非只保留最后一个。
  final Map<int, EngineStateSnapshot> _engineStates = {};
  StreamSubscription<EngineStateSnapshot>? _engineStateSub;

  /// 最新到达的引擎快照 (用于标题栏时间偏移徽章)
  EngineStateSnapshot? get _latestEngineState => _engineStates.isEmpty
      ? null
      : _engineStates.values
          .reduce((a, b) => a.timestamp.isAfter(b.timestamp) ? a : b);

  // 弹窗开始时间 (用于详情栏显示已耗时)
  final DateTime _startTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _finished = widget.initialFinished;
    // 从缓存恢复 BFE 会话上下文 / 引擎状态 (后台执行恢复场景)
    _session = widget.initialSession;
    // 并行模式: 优先使用快照集; 单快照 (旧场景) 回退填充 taskIndex=0
    final states = widget.initialEngineStates;
    if (states != null && states.isNotEmpty) {
      _engineStates.addAll(states);
    } else if (widget.initialEngineState != null) {
      _engineStates[widget.initialEngineState!.taskIndex] =
          widget.initialEngineState!;
    }
    _logSubscription = widget.logStream.listen(_onLog);
    _sessionSub = widget.sessionStream?.listen(_onSession);
    _engineStateSub = widget.engineStateStream?.listen(_onEngineState);
    if (widget.progressPoller != null) {
      // 立即查询一次建立基线, 之后按配置间隔轮询
      _pollProgress();
      _pollTimer = Timer.periodic(
          Duration(seconds: widget.progressPollInterval), (_) => _pollProgress());
    }
    // 记录已处于终态/活动态任务的耗时基准 (如后台恢复时已完成的任务)
    _updateTaskTimings();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _logSubscription?.cancel();
    _sessionSub?.cancel();
    _engineStateSub?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  Future<void> _pollProgress() async {
    if (_polling || _finished || !mounted) return;
    final poller = widget.progressPoller;
    if (poller == null) return;
    _polling = true;
    Map<int, double> result;
    try {
      result = await poller();
    } catch (_) {
      _polling = false;
      return;
    }
    if (!mounted) {
      _polling = false;
      return;
    }
    setState(() {
      for (final entry in result.entries) {
        final idx = entry.key;
        final ratio = entry.value;
        if (idx < 0 || idx >= widget.items.length) continue;
        _realProgress[idx] = ratio;
        // 达到阈值 → 视为完成 (显示 100%)
        if (ratio >= widget.completionThreshold) {
          _pollCompleted.add(idx);
          final item = widget.items[idx];
          if (item.state != PlaybackState.failed) {
            item.state = PlaybackState.completed;
            item.progress = 1.0;
          }
        }
      }
      // 真实进度判定完成的任务, 记录结束时间用于显示耗时
      _updateTaskTimings();
    });
    _polling = false;
    // 全部任务已有真实进度结论 → 停止轮询
    if (_pollCompleted.length >= widget.items.length) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _onLog(ProgressLogEvent event) {
    if (!mounted) return;
    // 在每次状态变化事件后刷新各任务耗时基准
    _updateTaskTimings();
    setState(() {
      _logs.add(event);
      // 限制日志条数 (对齐用户要求: 2000 条)
      if (_logs.length > _maxLogs) {
        _logs.removeRange(0, _logs.length - _maxLogs);
      }
    });
    // 自动滚动到底部 (仅当日志标签页可见且滚动条在底部附近)
    if (_tabIndex == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScrollController.hasClients &&
            _logScrollController.position.pixels >=
                _logScrollController.position.maxScrollExtent - 100) {
          _logScrollController
              .jumpTo(_logScrollController.position.maxScrollExtent);
        }
      });
    }
  }

  void _onSession(SessionContext ctx) {
    if (!mounted) return;
    setState(() => _session = ctx);
  }

  void _onEngineState(EngineStateSnapshot snap) {
    if (!mounted) return;
    setState(() => _engineStates[snap.taskIndex] = snap);
  }

  /// 复制全部日志到剪贴板
  Future<void> _copyLogs() async {
    if (_logs.isEmpty) return;
    final text = _logs
        .map((l) => '[${_timeStr(l.timestamp)}] [${l.level.name.toUpperCase()}] ${l.message}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制 ${_logs.length} 条日志到剪贴板'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// 清除全部日志
  void _clearLogs() {
    if (_logs.isEmpty) return;
    setState(() {
      _logs.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已清除日志'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// 外部调用标记全部完成
  void markFinished() {
    _updateTaskTimings();
    _pollTimer?.cancel();
    _pollTimer = null;
    if (mounted) setState(() => _finished = true);
    widget.onFinished?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 内容区高度自适应屏幕: 桌面 560, 小屏/横屏取 70% 屏高 (最低 320), 防止溢出
    final contentHeight = (MediaQuery.sizeOf(context).height * 0.7).clamp(320.0, 560.0);
    final totalCount = widget.items.length;
    int completedCount = 0;
    double progressSum = 0.0;
    for (var i = 0; i < totalCount; i++) {
      if (_isCompleted(i) || widget.items[i].state == PlaybackState.failed) {
        completedCount++;
      }
      progressSum += _effectiveProgress(i);
    }
    // 总进度条: 使用所有任务的平均进度 (含真实进度轮询的部分进度),
    // 而非仅计数已完成任务, 避免真实进度已查询出但进度条仍为 0% 的问题。
    final overallProgress =
        totalCount > 0 ? (progressSum / totalCount).clamp(0.0, 1.0) : 0.0;

    return AlertDialog(
      title: Row(
        children: [
          Text(widget.title),
          const SizedBox(width: 12),
          // 引擎实时状态徽章 (时间偏移, 取最新到达的快照)
          if (_latestEngineState != null)
            _EngineBadge(snap: _latestEngineState!),
          const Spacer(),
          Text(
            '$completedCount / $totalCount',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        // 宽度自适应: 桌面理想 680, 小屏不强制 (由 AlertDialog maxWidth 约束)
        constraints: const BoxConstraints(maxWidth: 680),
        child: SizedBox(
          // 必须固定宽度 (不能用 double.infinity): AlertDialog 内容被
          // IntrinsicWidth 包裹, width:∞ 会让固有宽度查询穿透到 ListView
          // (viewport 不支持固有尺寸测量) → 弹窗布局失败 → 程序卡死
          width: 680,
          height: contentHeight,
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 总进度条 (含百分比标签)
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: overallProgress,
                      minHeight: 6,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 70,
                  child: Text(
                    '${(overallProgress * 100).toInt()}%  ($completedCount/$totalCount)',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 标签页切换
            _buildTabs(theme),
            const SizedBox(height: 8),

            // 标签页内容
            Expanded(
              child: switch (_tabIndex) {
                0 => _buildProgressTab(theme),
                1 => _buildLogsTab(theme),
                _ => _buildDetailsTab(theme),
              },
            ),
          ],
          ),
        ),
      ),
      actions: [
        // 用 Row 包装以支持 Spacer (AlertDialog 的 actions 默认是 OverflowBar, 不支持 Expanded/Spacer)
        Row(
          children: [
            // 左下角: 后台执行按钮 (仅 onBackground 注入时显示)
            if (widget.onBackground != null)
              TextButton.icon(
                onPressed: widget.onBackground,
                icon: const Icon(Icons.minimize_outlined, size: 18),
                label: const Text('后台执行'),
              ),
            const Spacer(),
            if (_finished)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              )
            else
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                ),
                onPressed: () {
                  widget.onStop();
                  Navigator.of(context).pop();
                },
                child: const Text('停止'),
              ),
          ],
        ),
      ],
    );
  }

  /// 标签页切换条
  ///
  /// 使用 Wrap 布局防止窄屏溢出: 标签按钮 + 日志级别筛选在宽度不足时自动换行。
  Widget _buildTabs(ThemeData theme) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _TabButton(
          label: '进度',
          selected: _tabIndex == 0,
          onTap: () => setState(() => _tabIndex = 0),
          theme: theme,
        ),
        _TabButton(
          label: '日志 (${_filteredLogs.length}/${_logs.length})',
          selected: _tabIndex == 1,
          onTap: () => setState(() => _tabIndex = 1),
          theme: theme,
        ),
        _TabButton(
          label: '详情',
          selected: _tabIndex == 2,
          onTap: () => setState(() => _tabIndex = 2),
          theme: theme,
        ),
        // 日志级别筛选 (仅日志标签页显示, 右对齐)
        if (_tabIndex == 1) ...[
          const SizedBox(width: 12),
          _buildLogFilter(theme),
        ],
      ],
    );
  }

  /// 日志级别筛选下拉
  Widget _buildLogFilter(ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('级别:', style: theme.textTheme.labelSmall),
        const SizedBox(width: 4),
        DropdownButton<LogLevel?>(
          value: _logFilter,
          isDense: true,
          underline: const SizedBox(),
          items: const [
            DropdownMenuItem(value: null, child: Text('全部')),
            DropdownMenuItem(value: LogLevel.debug, child: Text('DEBUG')),
            DropdownMenuItem(value: LogLevel.info, child: Text('INFO')),
            DropdownMenuItem(value: LogLevel.success, child: Text('SUCCESS')),
            DropdownMenuItem(value: LogLevel.warning, child: Text('WARNING')),
            DropdownMenuItem(value: LogLevel.error, child: Text('ERROR')),
          ],
          onChanged: (v) => setState(() => _logFilter = v),
        ),
      ],
    );
  }

  /// 进度标签页
  Widget _buildProgressTab(ThemeData theme) {
    // 注意: 不能用 shrinkWrap (AlertDialog 内容被 IntrinsicWidth 包裹,
    // shrink-wrap 视口不支持固有尺寸测量, 会抛异常导致弹窗布局失败→程序卡死)
    return ListView.builder(
      itemCount: widget.items.length,
      itemBuilder: (context, index) {
        final item = widget.items[index];
        // 计算该任务耗时 (仅在开始/结束时间均已记录时)
        final Duration? elapsed = (item.startedAt != null && item.completedAt != null)
            ? item.completedAt!.difference(item.startedAt!)
            : null;
        final elapsedText = elapsed != null ? _formatDurationZh(elapsed) : null;
        return _TaskRow(
          item: item,
          displayProgress: _effectiveProgress(index),
          displayState: _effectiveState(index),
          realProgress: _realProgress[index],
          elapsedText: elapsedText,
        );
      },
    );
  }

  /// 日志标签页
  Widget _buildLogsTab(ThemeData theme) {
    final filtered = _filteredLogs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('日志', style: theme.textTheme.labelMedium),
            const SizedBox(width: 8),
            Text('${filtered.length}/${_logs.length} 条',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
            const Spacer(),
            // 复制日志按钮
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: _logs.isEmpty ? null : _copyLogs,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy_outlined,
                        size: 13, color: theme.colorScheme.primary),
                    const SizedBox(width: 3),
                    Text('复制',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                        )),
                  ],
                ),
              ),
            ),
            // 清除日志按钮
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: _logs.isEmpty ? null : _clearLogs,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.delete_outline,
                        size: 13, color: theme.colorScheme.error),
                    const SizedBox(width: 3),
                    Text('清除',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.error,
                        )),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: filtered.isEmpty
                ? Center(
                    child: Text('(无日志)',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )))
                : ListView.builder(
                    controller: _logScrollController,
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final log = filtered[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: SelectableText(
                          '[${_timeStr(log.timestamp)}] [${log.level.name.toUpperCase()}] ${log.message}',
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: _logColor(log.level, theme),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  /// 详情标签页: 任务执行摘要 + BFE 会话上下文 + 引擎实时状态
  ///
  /// 任务摘要板块始终显示 (适配所有功能: 进度上报/答案获取/下载)。
  /// BFE 会话和引擎状态板块仅在对应数据可用时显示 (仅进度上报场景)。
  Widget _buildDetailsTab(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 任务执行摘要 (始终显示)
          _SectionTitle(title: '任务执行摘要', theme: theme),
          _buildSummarySection(theme),
          const SizedBox(height: 16),

          // BFE 会话上下文 (仅进度上报场景, 有数据才显示)
          if (_session != null) ...[
            _SectionTitle(title: 'BFE 会话上下文', theme: theme),
            _SessionPanel(session: _session!, theme: theme),
            const SizedBox(height: 16),
          ],

          // 引擎实时状态 (仅进度上报场景, 有数据才显示)
          //
          // 并行执行模式: 每个执行中任务各有一个面板, 按任务索引排序展示;
          // 顺序执行模式: 只有一个面板 (行为与旧版一致)。
          if (_engineStates.isNotEmpty) ...[
            _SectionTitle(
              title: _engineStates.length > 1
                  ? '引擎实时状态 (${_engineStates.length} 个任务并发)'
                  : '引擎实时状态',
              theme: theme,
            ),
            // 并行模式: 面板间用分隔线区分, 顶部标注任务索引
            for (final entry
                in _engineStates.entries.toList()
                  ..sort((a, b) => a.key.compareTo(b.key)))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _EngineStatePanel(
                  snap: entry.value,
                  theme: theme,
                  showTaskBadge: _engineStates.length > 1,
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 任务执行摘要面板 (通用, 适配所有功能)
  Widget _buildSummarySection(ThemeData theme) {
    final total = widget.items.length;
    int completed = 0, failed = 0, running = 0, pending = 0;
    // 执行中任务标题列表 (并行模式: 多个任务并发, 全部收集)
    final runningTitles = <String>[];
    for (var i = 0; i < total; i++) {
      final item = widget.items[i];
      switch (item.state) {
        case PlaybackState.completed:
          completed++;
        case PlaybackState.failed:
          failed++;
        case PlaybackState.playing:
        case PlaybackState.focusChecking:
        case PlaybackState.interactive:
          running++;
          runningTitles.add(item.title);
        default:
          pending++;
      }
    }

    // 日志统计 (按级别)
    final logCounts = <LogLevel, int>{};
    for (final log in _logs) {
      logCounts[log.level] = (logCounts[log.level] ?? 0) + 1;
    }

    // 已耗时
    final elapsed = DateTime.now().difference(_startTime);
    final elapsedStr = _formatDuration(elapsed);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 任务统计行
          _summaryRow(theme, '任务总数', '$total'),
          _summaryRow(theme, '已完成', '$completed',
              valueColor: completed > 0 ? theme.colorScheme.primary : null),
          _summaryRow(theme, '执行中', '$running',
              valueColor: running > 0 ? Colors.orange : null),
          _summaryRow(theme, '失败', '$failed',
              valueColor: failed > 0 ? theme.colorScheme.error : null),
          _summaryRow(theme, '待执行', '$pending'),
          const Divider(height: 16),
          // 当前任务: 顺序模式显示单个任务; 并行模式列出全部执行中任务
          if (runningTitles.isEmpty)
            _summaryRow(theme, '当前任务', '(无)')
          else if (runningTitles.length == 1)
            _summaryRow(theme, '当前任务', runningTitles.first)
          else ...[
            _summaryRow(theme, '当前任务', '${runningTitles.length} 个任务并发',
                valueColor: Colors.orange),
            for (var i = 0; i < runningTitles.length; i++)
              Padding(
                padding: const EdgeInsets.only(left: 80, bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 任务序号徽章
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '任务 ${i + 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        runningTitles[i],
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          _summaryRow(theme, '开始时间', _timeStr(_startTime)),
          _summaryRow(theme, '已耗时', elapsedStr),
          _summaryRow(theme, '执行状态',
              _finished ? '已完成' : (running > 0 ? '执行中' : '等待中'),
              valueColor: _finished
                  ? theme.colorScheme.primary
                  : (running > 0 ? Colors.orange : null)),
          if (_logs.isNotEmpty) ...[
            const Divider(height: 16),
            _summaryRow(theme, '日志总数', '${_logs.length} 条'),
            // 日志级别分布
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final level in LogLevel.values)
                  if (logCounts[level] != null && logCounts[level]! > 0)
                    _logBadge(theme, level, logCounts[level]!),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(ThemeData theme, String label, String value,
      {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: valueColor,
                fontWeight: valueColor != null ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logBadge(ThemeData theme, LogLevel level, int count) {
    final color = switch (level) {
      LogLevel.debug => Colors.grey,
      LogLevel.info => Colors.blue,
      LogLevel.success => Colors.green,
      LogLevel.warning => Colors.orange,
      LogLevel.error => Colors.red,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        '${level.name.toUpperCase()} $count',
        style: TextStyle(fontSize: 10, color: color),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m ${d.inSeconds.remainder(60)}s';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }

  /// 中文耗时格式化: "xx时xx分xx秒" (省略前置为零的单位)
  ///
  /// 例: 1h2m3s → "1时2分3秒"; 65s → "1分5秒"; 9s → "9秒"。
  String _formatDurationZh(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h时$m分$s秒';
    if (m > 0) return '$m分$s秒';
    return '$s秒';
  }

  /// 记录每个任务的开始/结束时间 (供进度标签页显示"耗时")
  ///
  /// 在状态切换事件 ([_onLog]/[_pollProgress]) 中被调用:
  /// - 首次进入非初始化/非终态 → 记录 startedAt (任务真正开始工作)
  /// - 进入完成/失败终态 → 记录 completedAt (任务结束)
  ///
  /// 已经在构造时就处于终态的任务 (如后台恢复时已完成的任务) 不会错误地显示
  /// "0秒" —— 因为此时 startedAt 仍为 null, 详情面板与任务行均不展示耗时。
  void _updateTaskTimings() {
    for (var i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      // 开始: 离开初始化态且尚未记录过 (排除 cancelled 用户取消态)
      if (item.startedAt == null &&
          item.state != PlaybackState.initializing &&
          item.state != PlaybackState.cancelled) {
        item.startedAt = DateTime.now();
      }
      // 结束: 进入完成/失败终态且尚未记录过
      if (item.completedAt == null &&
          (item.state == PlaybackState.completed ||
              item.state == PlaybackState.failed)) {
        item.completedAt = DateTime.now();
      }
    }
  }

  /// 按级别筛选后的日志列表
  List<ProgressLogEvent> get _filteredLogs {
    if (_logFilter == null) return _logs;
    return _logs.where((l) => l.level == _logFilter).toList();
  }

  String _timeStr(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}'
        '.${dt.millisecond.toString().padLeft(3, '0')}';
  }

  Color _logColor(LogLevel level, ThemeData theme) {
    return switch (level) {
      LogLevel.debug => theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      LogLevel.info => theme.colorScheme.onSurfaceVariant,
      LogLevel.success => Colors.green,
      LogLevel.warning => Colors.orange,
      LogLevel.error => theme.colorScheme.error,
    };
  }

  /// 真实进度轮询是否已判定该任务完成 (达到阈值)
  bool _isCompleted(int index) =>
      _pollCompleted.contains(index) ||
      widget.items[index].state == PlaybackState.completed;

  /// 展示用进度: 轮询真实进度优先, 未覆盖则用引擎本地进度
  double _effectiveProgress(int index) {
    if (_pollCompleted.contains(index)) return 1.0;
    if (_realProgress.containsKey(index)) return _realProgress[index]!;
    return widget.items[index].progress;
  }

  /// 展示用状态: 轮询已完成的强制显示 completed (避免引擎后续事件回退状态)
  PlaybackState _effectiveState(int index) {
    if (_pollCompleted.contains(index)) return PlaybackState.completed;
    return widget.items[index].state;
  }
}

/// 标签页按钮
class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ThemeData theme;

  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: selected
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// 引擎实时状态徽章 (显示在标题栏)
class _EngineBadge extends StatelessWidget {
  final EngineStateSnapshot snap;
  const _EngineBadge({required this.snap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diffColor = snap.serverTimeDiffMs.abs() > 10000
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    return Tooltip(
      message: '服务器时间偏移: ${snap.serverTimeDiffStr}\n'
          '同步次数: ${snap.serverTimeSyncCount}\n'
          '检测点: ${snap.checkPointsStr}\n'
          '黑名单: ${snap.blacklistStr}\n'
          '心跳: ${snap.heartbeatOkCount} ok / ${snap.collectFailCount} fail',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: diffColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: diffColor.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 12, color: diffColor),
            const SizedBox(width: 4),
            Text(
              'Δt ${snap.serverTimeDiffStr}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: diffColor,
                fontFamily: 'monospace',
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 区块标题
class _SectionTitle extends StatelessWidget {
  final String title;
  final ThemeData theme;
  const _SectionTitle({required this.title, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// BFE 会话上下文面板
class _SessionPanel extends StatelessWidget {
  final SessionContext session;
  final ThemeData theme;

  const _SessionPanel({required this.session, required this.theme});

  @override
  Widget build(BuildContext context) {
    final rows = <_KV>[
      _KV('用户ID', session.userId),
      _KV('token', session.maskedToken),
      _KV('学校ID', session.schoolId),
      _KV('学校名称', session.schoolName ?? '(空)'),
      _KV('显示名', session.displayName ?? '(空)'),
      _KV('账号', session.account ?? '(空)'),
      _KV('省份码', session.provinceCode ?? '(空)'),
      _KV('sessionId', session.maskedSessionId),
      _KV('secret', session.maskedSecret),
      _KV('clientIp', session.clientIp.isEmpty ? '(空)' : session.clientIp),
      _KV('sdkVersion', session.sdkVersion),
      _KV('videoBizCode', session.videoBizCode),
      _KV('userAgent', session.userAgent),
      _KV('状态', _sessionStatusStr(session.status)),
      if (session.error != null) _KV('错误', session.error!, valueColor: theme.colorScheme.error),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows
            .map((r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: _KVRow(kv: r, theme: theme),
                ))
            .toList(),
      ),
    );
  }

  String _sessionStatusStr(SessionStatus s) {
    return switch (s) {
      SessionStatus.fetching => '⏳ 获取中...',
      SessionStatus.ready => '✓ 就绪',
      SessionStatus.degraded => '⚠ 降级 (部分字段缺失)',
      SessionStatus.failed => '✗ 失败',
    };
  }
}

/// 引擎实时状态面板
class _EngineStatePanel extends StatelessWidget {
  final EngineStateSnapshot snap;
  final ThemeData theme;

  /// 并行模式时显示任务索引徽章 (区分多个并发的任务面板)
  final bool showTaskBadge;

  const _EngineStatePanel({
    required this.snap,
    required this.theme,
    this.showTaskBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <_KV>[
      _KV('当前任务', '[${snap.taskIndex + 1}] ${snap.taskTitle}'),
      _KV('状态', '${snap.state.name}${snap.message != null ? " - ${snap.message}" : ""}'),
      _KV('进度', '${(snap.progress * 100).toStringAsFixed(1)}% (${snap.playedSeconds}s/${snap.totalSeconds}s)'),
      _KV('服务器时间偏移', snap.serverTimeDiffStr,
          valueColor: snap.serverTimeDiffMs.abs() > 10000
              ? theme.colorScheme.error
              : theme.colorScheme.primary),
      _KV('服务器时间同步', '${snap.serverTimeSyncCount} 次, 末次 ts=${snap.serverLastTs}'),
      _KV('检测点(videoCheckPoint)', snap.checkPointsStr),
      _KV('point_time_id', '${snap.lastPointTimeId} / ${snap.pointNum}'),
      _KV('黑名单状态', snap.blacklistStr,
          valueColor: snap.isBlacklisted
              ? theme.colorScheme.error
              : theme.colorScheme.primary),
      _KV('认真度检测', snap.seriousCheckStr),
      _KV('认真度检测点', '${snap.completedCheckPointCount}/${snap.videoCheckPoints.length}'),
      _KV('互动视频', snap.isInteractiveVideo ? '是' : '否'),
      _KV('互动答题完成', '${snap.interactiveDoneCount}/${snap.interactiveTotalCount}'),
      _KV('心跳成功', '${snap.heartbeatOkCount} 次'),
      _KV('上报失败', '${snap.collectFailCount} 次',
          valueColor: snap.collectFailCount > 0
              ? theme.colorScheme.error
              : null),
      if (snap.brushRounds > 0)
        _KV('快刷轮数', '${snap.brushRounds} 轮, 最终进度 ${(snap.brushFinalRatio * 100).toStringAsFixed(1)}%'),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 并行模式任务标识
          if (showTaskBadge)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '任务 ${snap.taskIndex + 1}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ...rows.map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: _KVRow(kv: r, theme: theme),
              )),
        ],
      ),
    );
  }
}

/// 键值对
class _KV {
  final String key;
  final String value;
  final Color? valueColor;
  const _KV(this.key, this.value, {this.valueColor});
}

/// 键值对行
///
/// 宽屏 (≥420px): `Row(label 160px + ': ' + Expanded(value))`
/// 窄屏 (<420px): label + ':' 一行, value 换行缩进显示 (在 ':' 后换行)
class _KVRow extends StatelessWidget {
  final _KV kv;
  final ThemeData theme;
  const _KVRow({required this.kv, required this.theme});

  @override
  Widget build(BuildContext context) {
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFamily: 'monospace',
      fontSize: 11,
    );
    final valueStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      fontSize: 11,
      color: kv.valueColor ?? theme.colorScheme.onSurface,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄屏: label + ':' 一行, value 换行缩进
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  style: labelStyle,
                  children: [
                    TextSpan(text: kv.key),
                    TextSpan(text: ':', style: labelStyle),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 1),
                child: SelectableText(kv.value, style: valueStyle),
              ),
            ],
          );
        }
        // 宽屏: 原始 Row 布局
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 160,
              child: Text(kv.key, style: labelStyle),
            ),
            const Text(': '),
            Expanded(
              child: SelectableText(kv.value, style: valueStyle),
            ),
          ],
        );
      },
    );
  }
}

/// 单条任务行
class _TaskRow extends StatelessWidget {
  final TaskProgressItem item;
  final double displayProgress;
  final PlaybackState displayState;
  final double? realProgress; // 真实进度 (来自轮询)

  /// 耗时文本 (已完成/失败任务在标题下方显示 "耗时：xx时xx分xx秒")
  final String? elapsedText;

  const _TaskRow({
    required this.item,
    required this.displayProgress,
    required this.displayState,
    this.realProgress,
    this.elapsedText,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final icon = switch (displayState) {
      PlaybackState.completed => const Icon(Icons.check_circle,
          color: Colors.green, size: 18),
      PlaybackState.failed => const Icon(Icons.error,
          color: Colors.red, size: 18),
      PlaybackState.cancelled => const Icon(Icons.cancel,
          color: Colors.grey, size: 18),
      _ => const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
    };

    // 进度文本: 有真实进度时仅显示真实进度, 否则显示本地进度
    final progressText = realProgress != null
        ? '${(realProgress! * 100).toInt()}%'
        : '${(displayProgress * 100).toInt()}%';
    // 进度条颜色: 完成绿色, 失败红色, 其余主色
    final barColor = displayState == PlaybackState.completed
        ? Colors.green
        : (displayState == PlaybackState.failed
            ? Colors.red
            : theme.colorScheme.primary);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              icon,
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (item.message != null)
                      Text(
                        item.message!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 10,
                        ),
                      ),
                    // 已完成/失败任务在标题下方显示耗时
                    if (elapsedText != null &&
                        (displayState == PlaybackState.completed ||
                            displayState == PlaybackState.failed))
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Row(
                          children: [
                            Icon(Icons.schedule,
                                size: 10,
                                color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 3),
                            Text(
                              '耗时：$elapsedText',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 50,
                child: Text(
                  progressText,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          // 可视进度条: 实时反映真实进度轮询结果
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: displayProgress.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// BFE 会话上下文 (供 UI 详情面板显示)
///
/// 包含用户身份 + BFE 会话配置 + 端点信息, 对齐 mstplayer_behavior_doc.md §4/§5
class SessionContext {
  /// 用户 ID (CommonPackage.userid)
  final String userId;

  /// 用户 token (CommonPackage.mstid, 同请求头 Token)
  final String token;

  /// 学校 ID (CommonPackage.schoolId)
  final String schoolId;

  /// 显示名称
  final String? displayName;

  /// 学校名称
  final String? schoolName;

  /// 用户省份码 (CommonPackage.memberProvinceCode)
  final String? provinceCode;

  /// 账号
  final String? account;

  /// 手机号
  final String? mobile;

  /// BFE 会话 ID (X-Bfe-Session-Id 头)
  final String sessionId;

  /// HMAC-SHA1 签名密钥 (globalInfo.secret)
  final String secret;

  /// 客户端 IP (CommonPackage.ip)
  final String clientIp;

  /// SDK 版本 (CommonPackage.sdkVersion)
  final String sdkVersion;

  /// 浏览器 UA (CommonPackage.browser_ver)
  final String userAgent;

  /// 视频业务码 (CommonPackage.videoBizCode)
  final String videoBizCode;

  /// 会话状态
  final SessionStatus status;

  /// 错误描述 (status=degraded/failed 时填)
  final String? error;

  /// 时间戳
  final DateTime timestamp;

  SessionContext({
    required this.userId,
    required this.token,
    required this.schoolId,
    this.displayName,
    this.schoolName,
    this.provinceCode,
    this.account,
    this.mobile,
    required this.sessionId,
    required this.secret,
    required this.clientIp,
    required this.sdkVersion,
    required this.userAgent,
    required this.videoBizCode,
    required this.status,
    this.error,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// token 脱敏显示
  String get maskedToken {
    if (token.length <= 12) return token;
    return '${token.substring(0, 8)}...${token.substring(token.length - 4)}';
  }

  /// secret 脱敏显示
  String get maskedSecret {
    if (secret.isEmpty) return '(空)';
    if (secret.length <= 8) return secret;
    return '${secret.substring(0, 8)}...';
  }

  /// sessionId 脱敏显示
  String get maskedSessionId {
    if (sessionId.isEmpty) return '(空)';
    if (sessionId.length <= 16) return sessionId;
    return '${sessionId.substring(0, 16)}...';
  }
}

/// 会话状态
enum SessionStatus {
  /// 正在获取 BFE 配置
  fetching,

  /// BFE 会话就绪 (sessionId + secret + clientIp 均非空)
  ready,

  /// 部分字段缺失, 使用降级值
  degraded,

  /// 获取失败
  failed,
}

/// 引擎实时状态快照 (供 UI 详情面板显示)
///
/// 对齐 mstplayer_behavior_doc.md §5 描述的运行时状态:
/// - 服务器时间偏移 / 同步次数 (checkDiffTime)
/// - 客户端生成的 videoCheckPoint 检测点数组
/// - 黑名单状态 (getVideodp)
/// - 认真度检测降级配置 (getSeriousCheckDownGradeConfig)
/// - 互动视频标记
/// - 心跳成功 / 上报失败计数
class EngineStateSnapshot {
  /// 当前任务索引 (在批量任务列表中的位置)
  final int taskIndex;

  /// 当前任务标题
  final String taskTitle;

  /// 播放状态
  final PlaybackState state;

  /// 进度 (0.0 ~ 1.0)
  final double progress;

  /// 已播放秒数
  final int playedSeconds;

  /// 总秒数 (估算 = pointNum * heartbeatInterval)
  final int totalSeconds;

  /// 服务器时间偏移 (ms, server_ts - local_ts)
  final int serverTimeDiffMs;

  /// 服务器时间同步次数
  final int serverTimeSyncCount;

  /// 服务器最后同步时间戳 (ms)
  final int serverLastTs;

  /// 客户端生成的检测点数组 (秒)
  final List<int> videoCheckPoints;

  /// 已完成的认真度检测点数 (用于 UI 显示 "已完成/全部检测点")
  final int completedCheckPointCount;

  /// 互动点总数 (用于 UI 显示 "已完成/全部互动点")
  final int interactiveTotalCount;

  /// 已完成的互动点数 (用于 UI 显示 "已完成/全部互动点")
  final int interactiveDoneCount;

  /// 黑名单状态 (true → 滑块型, false → 确认型)
  final bool isBlacklisted;

  /// 互动视频标记
  final bool isInteractiveVideo;

  /// 认真度检测降级配置
  final SeriousCheckConfig seriousCheckConfig;

  /// 快刷已完成的轮数
  final int brushRounds;

  /// 快刷最终进度比例
  final double brushFinalRatio;

  /// 心跳成功次数
  final int heartbeatOkCount;

  /// 上报失败次数
  final int collectFailCount;

  /// 认真度检测是否全部通过
  final bool lessonFocusDone;

  /// 互动答题是否完成
  final bool lessonInteractiveDone;

  /// 上次 point_time_id
  final int lastPointTimeId;

  /// 会话总检测点数
  final int pointNum;

  /// 当前事件消息
  final String? message;

  /// 时间戳
  final DateTime timestamp;

  EngineStateSnapshot({
    required this.taskIndex,
    required this.taskTitle,
    required this.state,
    required this.progress,
    required this.playedSeconds,
    required this.totalSeconds,
    required this.serverTimeDiffMs,
    required this.serverTimeSyncCount,
    required this.serverLastTs,
    required this.videoCheckPoints,
    required this.completedCheckPointCount,
    required this.interactiveTotalCount,
    required this.interactiveDoneCount,
    required this.isBlacklisted,
    required this.isInteractiveVideo,
    required this.seriousCheckConfig,
    required this.brushRounds,
    required this.brushFinalRatio,
    required this.heartbeatOkCount,
    required this.collectFailCount,
    required this.lessonFocusDone,
    required this.lessonInteractiveDone,
    required this.lastPointTimeId,
    required this.pointNum,
    this.message,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// 时间偏移的可读字符串
  String get serverTimeDiffStr {
    final diff = serverTimeDiffMs;
    if (diff == 0) return '0ms';
    final sign = diff > 0 ? '+' : '-';
    final abs = diff.abs();
    if (abs < 1000) return '$sign${abs}ms';
    return '$sign${(abs / 1000).toStringAsFixed(2)}s';
  }

  /// 检测点列表的字符串表示
  String get checkPointsStr =>
      videoCheckPoints.isEmpty ? '(无)' : '${videoCheckPoints.join(', ')}s';

  /// 黑名单状态的可读字符串
  String get blacklistStr =>
      isBlacklisted ? '在黑名单 → 滑块型' : '普通用户 → 确认型';

  /// 认真度检测状态字符串
  String get seriousCheckStr {
    if (seriousCheckConfig.isDowngrade) {
      return '已降级 (level=0, needLog=${seriousCheckConfig.needLog})';
    }
    return '正常 (level=${seriousCheckConfig.level}, needLog=${seriousCheckConfig.needLog})';
  }
}

// ─── 后台执行: 弹窗/浮窗切换管理器 ──────────────────────────────────────────

/// 任务弹窗管理器: 管理弹窗与浮窗之间的切换
///
/// 用户点击"后台执行"后, 弹窗隐藏为浮窗 (OverlayEntry);
/// 点击浮窗恢复弹窗。支持多个任务同时后台执行 (每个 manager 独立)。
///
/// 跨平台: 基于 Flutter Overlay, 同时支持 Windows / Android / Web。
class _TaskDialogManager {
  final BuildContext _context;
  final List<TaskProgressItem> _items;
  final Stream<ProgressLogEvent> _logStream;
  final VoidCallback _onStop;
  final String _title;
  final GlobalKey<TaskProgressDialogState>? _dialogKey;
  final Future<Map<int, double>> Function()? _progressPoller;
  final int _progressPollInterval;
  final double _completionThreshold;
  final Stream<SessionContext>? _sessionStream;
  final Stream<EngineStateSnapshot>? _engineStateStream;

  OverlayEntry? _floatEntry;
  bool _backgroundMode = false;

  // 最新快照缓存: 后台执行恢复时传给新 dialog, 避免详情栏空白
  // (上游 stream 是 broadcast, 不会重放旧值, 必须由 manager 持有最新值)
  SessionContext? _lastSession;

  /// 引擎实时状态快照集 (key=taskIndex, 并行模式下每个任务一份)
  final Map<int, EngineStateSnapshot> _lastEngineStates = {};
  StreamSubscription<SessionContext>? _sessionCacheSub;
  StreamSubscription<EngineStateSnapshot>? _engineStateCacheSub;

  /// 从 items 实时计算完成状态 (后台执行时 dialogKey.currentState 为 null,
  /// 无法通过 markFinished 获取, 因此直接从 items 推导)
  bool get _finished {
    if (_items.isEmpty) return false;
    return _items.every((item) =>
        item.state == PlaybackState.completed ||
        item.state == PlaybackState.failed);
  }

  _TaskDialogManager({
    required BuildContext context,
    required List<TaskProgressItem> items,
    required Stream<ProgressLogEvent> logStream,
    required VoidCallback onStop,
    required String title,
    GlobalKey<TaskProgressDialogState>? dialogKey,
    Future<Map<int, double>> Function()? progressPoller,
    int progressPollInterval = 60,
    double completionThreshold = 0.8,
    Stream<SessionContext>? sessionStream,
    Stream<EngineStateSnapshot>? engineStateStream,
  })  : _context = context,
        _items = items,
        _logStream = logStream,
        _onStop = onStop,
        _title = title,
        _dialogKey = dialogKey,
        _progressPoller = progressPoller,
        _progressPollInterval = progressPollInterval,
        _completionThreshold = completionThreshold,
        _sessionStream = sessionStream,
        _engineStateStream = engineStateStream {
    // 持久订阅: 即使弹窗 dispose, manager 仍持续接收最新快照
    _sessionCacheSub = _sessionStream?.listen((s) => _lastSession = s);
    _engineStateCacheSub =
        _engineStateStream?.listen((s) => _lastEngineStates[s.taskIndex] = s);
  }

  /// 首次显示弹窗
  Future<void> show() => _showDialog();

  Future<void> _showDialog() async {
    await showDialog(
      context: _context,
      barrierDismissible: false,
      builder: (_) => TaskProgressDialog(
        key: _dialogKey,
        items: _items,
        logStream: _logStream,
        onStop: _onStop,
        title: _title,
        progressPoller: _progressPoller,
        progressPollInterval: _progressPollInterval,
        completionThreshold: _completionThreshold,
        sessionStream: _sessionStream,
        engineStateStream: _engineStateStream,
        onBackground: _switchToFloat,
        initialFinished: _finished,
        initialSession: _lastSession,
        initialEngineStates:
            _lastEngineStates.isEmpty ? null : Map.of(_lastEngineStates),
      ),
    );
    // 弹窗关闭后 (用户点停止/关闭, 非后台模式), 移除浮窗并释放订阅
    if (!_backgroundMode) {
      _removeFloat();
      _sessionCacheSub?.cancel();
      _engineStateCacheSub?.cancel();
    }
  }

  /// 切换到浮窗模式
  void _switchToFloat() {
    _backgroundMode = true;
    // 关闭弹窗 (不调用 onStop, 只是隐藏)
    // ⚠️ 必须使用 rootNavigator: showDialog 默认 useRootNavigator=true,
    // dialog 路由在 root Navigator 上; 若用子 Navigator (ShellRoute) 的 pop,
    // 会误 pop 掉 ShellRoute 子页面导致黑屏。
    Navigator.of(_context, rootNavigator: true).pop();
    // 显示浮窗
    _showFloat();
  }

  void _showFloat() {
    _removeFloat();
    _floatEntry = OverlayEntry(
      builder: (ctx) => _TaskFloatButton(
        title: _title,
        items: _items,
        finished: _finished,
        onTap: _switchToDialog,
        onClose: () {
          _removeFloat();
          _onStop();
        },
      ),
    );
    Overlay.of(_context, rootOverlay: true).insert(_floatEntry!);
  }

  void _switchToDialog() {
    _removeFloat();
    _backgroundMode = false;
    _showDialog();
  }

  void _removeFloat() {
    _floatEntry?.remove();
    _floatEntry = null;
  }
}

/// 浮窗按钮: 半透明, 可拖动, 显示 ">_" 图标和任务进度
///
/// 跨平台 (Windows/Android/Web): 纯 Flutter Overlay 实现, 无需系统权限。
class _TaskFloatButton extends StatefulWidget {
  final String title;
  final List<TaskProgressItem> items;
  final bool finished;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _TaskFloatButton({
    required this.title,
    required this.items,
    required this.finished,
    required this.onTap,
    required this.onClose,
  });

  @override
  State<_TaskFloatButton> createState() => _TaskFloatButtonState();
}

class _TaskFloatButtonState extends State<_TaskFloatButton> {
  Offset _position = Offset.zero;
  bool _initialized = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // 每秒刷新: 实时显示 items 进度变化 (OverlayEntry 不自动重建)
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// 从 items 实时计算完成状态 (覆盖 widget.finished)
  bool get _isFinished {
    if (widget.items.isEmpty) return widget.finished;
    return widget.items.every((item) =>
        item.state == PlaybackState.completed ||
        item.state == PlaybackState.failed);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // 初始位置: 右下角
    if (!_initialized) {
      _position = Offset(size.width - 72, size.height - 160);
      _initialized = true;
    }

    // 计算进度
    int completed = 0;
    for (final item in widget.items) {
      if (item.state == PlaybackState.completed ||
          item.state == PlaybackState.failed) {
        completed++;
      }
    }
    final total = widget.items.length;
    final ratio = total > 0 ? completed / total : 0.0;

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: widget.onTap,
          onPanUpdate: (details) {
            setState(() {
              _position += details.delta;
              // 边界约束
              _position = Offset(
                _position.dx.clamp(0, size.width - 56),
                _position.dy.clamp(0, size.height - 56),
              );
            });
          },
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: _isFinished
                  ? Colors.green.withValues(alpha: 0.75)
                  : Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Stack(
              children: [
                // 进度环背景
                if (!_isFinished && total > 0)
                  Positioned.fill(
                    child: CircularProgressIndicator(
                      value: ratio,
                      strokeWidth: 2,
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                    ),
                  ),
                // 图标 ">_"
                Center(
                  child: Text(
                    '>_',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                // 计数徽章
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white, width: 1),
                    ),
                    child: Text(
                      '$completed/$total',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                // 关闭按钮 (右上角)
                Positioned(
                  right: 0,
                  top: 0,
                  child: GestureDetector(
                    onTap: widget.onClose,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 10,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
