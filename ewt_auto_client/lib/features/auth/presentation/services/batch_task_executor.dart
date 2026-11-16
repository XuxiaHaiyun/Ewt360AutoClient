/// 批量任务执行器，支持进度上报/试题答案/下载视频/下载试题 4 项任务的多账号批量执行（串行/并行可选，可停止）。
/// 每账号独立 DioClient 与代理，日志经 accountToken 标记归属账号供进度弹窗按账号筛选。
library;

import 'dart:async';

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/utils/concurrency.dart';
import '../../../answer/domain/entities/answer_filter_config.dart';
import '../../../answer/domain/entities/answer_config.dart';
import '../../../answer/presentation/services/answer_export_helper.dart';
import '../../../answer/presentation/services/answer_service.dart';
import '../../../answer/presentation/services/answer_submit_helper.dart';
import '../../../download/domain/entities/download_config.dart';
import '../../../player/domain/services/video_source_resolver.dart';
import '../../../download/presentation/services/download_service.dart';
import '../../../homework/data/datasources/homework_remote_datasource.dart';
import '../../../homework/domain/entities/task_filter_config.dart';
import '../../../player/domain/entities/report_config.dart';
import '../../../player/domain/entities/video_session.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../../player/presentation/services/progress_report_service.dart';
import '../../domain/entities/user_session.dart';

/// 批量任务执行器
///
/// 用于登录页"批量执行任务"中的进度上报/试题答案/下载视频/下载试题 4 项任务。
/// 对齐 Python: gui/workers/batch_operation.py BatchOperationWorker
///   - 每账号独立 DioClient (避免共享 token, 可配置独立代理)
///   - 串行/并行可选 (parallel=true 时所有账号同时执行)
///   - 可停止
///
/// 与 KeepAliveService 不同: 本服务执行有限任务, 所有账号处理完即结束。
///
/// 日志与状态:
///   - 所有账号作用域内的日志通过 [accountToken] 标记归属账号,
///     供进度弹窗按账号筛选查看 (需求: 分别查看各账号任务进度/日志/详情)
///   - 状态流携带每账号 startedAt, 供详情页展示耗时
class BatchTaskExecutor {
  /// 任务类型常量
  static const String kTaskReport = '进度上报';
  static const String kTaskAnswers = '试题答案';
  static const String kTaskDownloadVideo = '下载视频';
  static const String kTaskDownloadPaper = '下载试题';

  /// 支持的任务类型
  static const supportedTasks = [
    kTaskReport,
    kTaskAnswers,
    kTaskDownloadVideo,
    kTaskDownloadPaper,
  ];

  final List<UserSession> _accounts;
  final EndpointConfig _endpointConfig;
  final String _taskType;

  /// 是否并行执行所有账号
  ///
  /// false (默认): 串行执行, 一个账号完成后再执行下一个
  /// true: 所有账号同时执行 (每账号独立 DioClient, 无 token 冲突)
  final bool parallel;

  /// 作业级筛选配置 (status/subject/type)
  ///
  /// 对应 TaskFilterDialog, 用于过滤 getHomeworkList 拉取的作业范围
  final TaskFilterConfig taskFilterConfig;

  /// 进度上报配置 (仅 kTaskReport 任务使用)
  ///
  /// 对齐 Python: BatchReportConfigDialog.get_config() → Worker.config
  /// 由调用方在 _startBatchTask 中先打开 ReportConfigPage 获取
  /// null 时使用 ReportConfig() 默认值
  final ReportConfig? reportConfig;

  /// 试题答案配置 (仅 kTaskAnswers 任务使用)
  ///
  /// 包含获取方案 + 展示字段 + 课程级过滤 + 获取完成操作(自动提交)
  /// 由调用方在 _startBatchTask 中先打开 AnswerConfigPage 获取
  final AnswerFilterConfig? answerFilterConfig;

  /// 试题答案完整配置 (仅 kTaskAnswers 任务使用)
  ///
  /// 含获取方案/展示字段/获取完成操作(自动提交) 等 [AnswerConfig] 全部字段;
  /// [answerFilterConfig] 为其中的过滤部分, 二者由同一个
  /// [AnswerConfigPage] 返回 ([AnswerConfigResult])。
  final AnswerConfig? answerConfig;

  /// 下载配置 (仅 kTaskDownloadVideo / kTaskDownloadPaper 使用)
  ///
  /// 包含课程级过滤 + 字体配置 (仅试题下载使用字体)
  /// 由调用方在 _startBatchTask 中先弹 DownloadConfigDialog 获取
  final DownloadConfig? downloadConfig;

  final _logController = StreamController<ProgressLogEvent>.broadcast();
  final _stateController =
      StreamController<Map<String, AccountBatchState>>.broadcast();

  /// 每账号实时状态
  final Map<String, AccountBatchState> _states = {};

  /// 并行模式最大并发账号数 (防全量并发导致资源耗尽/服务端限流)
  static const int _parallelLimit = 5;

  bool _stopped = false;
  bool _disposed = false;

  BatchTaskExecutor({
    required List<UserSession> accounts,
    required EndpointConfig endpointConfig,
    required String taskType,
    this.taskFilterConfig = const TaskFilterConfig.defaults(),
    this.reportConfig,
    this.answerFilterConfig,
    this.answerConfig,
    this.downloadConfig,
    this.parallel = false,
  })  : _accounts = accounts,
        _endpointConfig = endpointConfig,
        _taskType = taskType {
    for (final acc in _accounts) {
      _states[acc.token] = AccountBatchState(
        account: acc,
        status: BatchStatus.pending,
        totalCourses: 0,
        processedCourses: 0,
        message: '等待开始',
      );
    }
  }

  Stream<ProgressLogEvent> get logStream => _logController.stream;
  Stream<Map<String, AccountBatchState>> get stateStream =>
      _stateController.stream;
  Map<String, AccountBatchState> get states => Map.unmodifiable(_states);
  bool get isRunning => !_stopped && !_disposed;
  String get taskType => _taskType;

  /// 账号列表 (供详情页展示)
  List<UserSession> get accounts => List.unmodifiable(_accounts);

  void _log(String msg,
      {LogLevel level = LogLevel.info, String? accountToken}) {
    if (_disposed || _logController.isClosed) return;
    _logController.add(
      ProgressLogEvent(msg, level: level, accountToken: accountToken),
    );
  }

  void _updateState(String token, AccountBatchState newState) {
    _states[token] = newState;
    if (!_stateController.isClosed) {
      _stateController.add(Map.unmodifiable(_states));
    }
  }

  /// 启动批量任务
  ///
  /// parallel=false: 串行执行, 一个账号完成后再执行下一个
  /// parallel=true: 所有账号同时执行 (Future.wait 并发)
  Future<void> start() async {
    _stopped = false;
    _log('开始批量$_taskType: ${_accounts.length} 个账号'
        '${parallel ? " (并行模式)" : ""}');
    _log('  任务筛选: status=${taskFilterConfig.status ?? "(全部)"}, '
        'subject=${taskFilterConfig.subject ?? "(全部)"}, '
        'type=${taskFilterConfig.type ?? "(全部)"}');

    if (parallel) {
      // ─── 并行模式: 所有账号并发执行 (有限并发, 防资源耗尽/限流) ───
      await runWithConcurrency(
        [for (var i = 0; i < _accounts.length; i++) () => _executeAccountSafely(_accounts[i], i)],
        concurrency: _parallelLimit,
      );
    } else {
      // ─── 串行模式: 逐个账号执行 ───
      for (int i = 0; i < _accounts.length; i++) {
        if (_stopped || _disposed) break;
        await _executeAccountSafely(_accounts[i], i);
      }
    }

    _log('批量$_taskType已结束', level: LogLevel.warning);
  }

  /// 执行单个账号任务 (含状态更新和异常捕获)
  ///
  /// 串行/并行模式共用此方法, 确保状态更新和日志逻辑一致。
  Future<void> _executeAccountSafely(UserSession acc, int index) async {
    if (_stopped || _disposed) return;

    final displayName = acc.displayName ?? acc.account ?? acc.userId;
    final token = acc.token;

    _log('── [${index + 1}/${_accounts.length}] $displayName ──',
        accountToken: token);
    _updateState(token, AccountBatchState(
      account: acc,
      status: BatchStatus.running,
      totalCourses: 0,
      processedCourses: 0,
      message: '正在拉取作业列表...',
      startedAt: DateTime.now(),
    ));

    try {
      await _executeForAccount(acc);
      if (_stopped || _disposed) return;
      final s = _states[token]!;
      _updateState(token, s.copyWith(
        status: BatchStatus.done,
        message: '完成: ${s.processedCourses}/${s.totalCourses} 课程',
      ));
      _log('  ✓ [$displayName] 完成',
          level: LogLevel.success, accountToken: token);
    } catch (e) {
      if (_stopped || _disposed) return;
      _log('  ✗ [$displayName] 失败: $e',
          level: LogLevel.error, accountToken: token);
      final s = _states[token]!;
      _updateState(token, s.copyWith(
        status: BatchStatus.failed,
        message: '失败: $e',
      ));
    }
  }

  /// 单账号执行链路 (对齐 Python `_execute_for_account`)
  ///
  /// 对齐 Python 流程的 5%/10%/50%/100% 进度阶段:
  ///   1. 5%  - 初始化 DioClient + 校验 token
  ///   2. 10% - 拉取作业列表
  ///   3. 10%~50% - 拉取所有作业下的所有课程 (循环)
  ///   4. 50%~100% - 执行具体任务 (_doReport / _doAnswers / _doDownload)
  Future<void> _executeForAccount(UserSession acc) async {
    if (_stopped || _disposed) return;

    final token = acc.token;

    // 1. 创建独立 DioClient (对齐 Python EWTClient(), 支持每账号独立代理)
    _log('  [5%] 初始化 DioClient...', accountToken: token);
    _updateState(token, _states[token]!.copyWith(
      status: BatchStatus.running,
      totalCourses: 0,
      processedCourses: 0,
      message: '初始化 DioClient...',
    ));

    if (acc.token.isEmpty) {
      throw '缺少 token';
    }
    if (acc.schoolId.isEmpty) {
      throw '缺少 schoolId (账号未登录或信息不全)';
    }

    final client = DioClient(endpointConfig: _endpointConfig, proxy: acc.proxy);
    client.token = acc.token;
    _log('  token=${acc.token.substring(0, 8)}..., schoolId=${acc.schoolId}, '
        'userId=${acc.userId}', accountToken: token);
    _log('  代理: ${acc.proxy == null || acc.proxy!.trim().isEmpty ? "(直连)" : acc.proxy}',
        accountToken: token);

    // 2. 拉取作业列表 (对齐 Python: get_homework_info)
    _log('  [10%] 正在拉取作业列表...', accountToken: token);
    _updateState(token, _states[token]!.copyWith(
      status: BatchStatus.running,
      totalCourses: 0,
      processedCourses: 0,
      message: '正在拉取作业列表...',
    ));

    final homeworkRemote = HomeworkRemoteDataSource(client);
    final List<dynamic> homeworkList;
    try {
      homeworkList = await homeworkRemote.getHomeworkList(
        schoolId: acc.schoolId,
        subject: taskFilterConfig.subject,
        type: taskFilterConfig.type,
        status: taskFilterConfig.status,
        pageIndex: 1,
        pageSize: 100,
      );
    } catch (e) {
      _log('  ✗ 拉取作业列表失败: $e',
          level: LogLevel.error, accountToken: token);
      rethrow;
    }

    if (_stopped || _disposed) return;

    if (homeworkList.isEmpty) {
      _log('  作业列表为空, 跳过此账号',
          level: LogLevel.warning, accountToken: token);
      return;
    }
    _log('  作业数: ${homeworkList.length}', accountToken: token);

    // 3. 拉取所有作业下的所有课程 (对齐 Python: _fetch_all_courses)
    final allCourses = <Map<String, dynamic>>[];
    final totalHw = homeworkList.length;
    int hwIdx = 0;
    for (final hw in homeworkList) {
      if (_stopped || _disposed) return;
      hwIdx++;
      if (hw is! Map<String, dynamic>) continue;

      final homeworkId = hw['homeworkId']?.toString() ??
          hw['id']?.toString() ??
          '';
      if (homeworkId.isEmpty) continue;

      // 进度: 10% ~ 50% (对齐 Python pct = 10 + int(idx / total * 40))
      final pct = 10 + (hwIdx / totalHw * 40).toInt();
      final hwTitle = hw['homeworkName']?.toString() ??
          hw['title']?.toString() ??
          homeworkId;
      _log('  [$pct%] 作业 $hwIdx/$totalHw: $hwTitle (id=$homeworkId)',
          accountToken: token);

      try {
        final statsMap = await homeworkRemote.getDaySubjectStat(
          homeworkId: homeworkId,
          schoolId: acc.schoolId,
        );
        final dateList = (statsMap['dateStat'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _log('    日期数: ${dateList.length}', accountToken: token);

        for (final day in dateList) {
          if (_stopped || _disposed) return;
          final dayId = day['dateId']?.toString() ??
              day['dayId']?.toString() ??
              day['id']?.toString() ??
              '';
          if (dayId.isEmpty) continue;

          final result = await homeworkRemote.getHomeworkTasks(
            homeworkId: homeworkId,
            schoolId: acc.schoolId,
            dayId: dayId,
            pageIndex: 1,
            pageSize: 200,
          );
          final list = result['data'] as List<dynamic>? ?? [];
          _log('    $dayId: ${list.length} 个课程', accountToken: token);
          for (final c in list) {
            if (c is Map<String, dynamic>) {
              // 注入 homeworkId / schoolId / dayId 便于下游 service 使用
              c['homeworkId'] = homeworkId;
              c['schoolId'] = acc.schoolId;
              c['dayId'] = dayId;
              allCourses.add(c);
            }
          }
        }
      } catch (e) {
        _log('  作业 $homeworkId 拉取失败: $e',
            level: LogLevel.warning, accountToken: token);
      }
    }

    if (_stopped || _disposed) return;

    _updateState(token, _states[token]!.copyWith(
      status: BatchStatus.running,
      totalCourses: allCourses.length,
      processedCourses: 0,
      message: '共 ${allCourses.length} 个课程',
    ));

    if (allCourses.isEmpty) {
      _log('  课程列表为空, 跳过此账号',
          level: LogLevel.warning, accountToken: token);
      return;
    }
    _log('  课程总数: ${allCourses.length}, 开始执行$_taskType',
        accountToken: token);

    // 4. 分发到对应 service (对齐 Python: _do_report / _do_answers / _do_download)
    await _dispatchTask(client, acc, allCourses);
  }

  /// 分发任务到对应 service (对齐 Python `_dispatchTask`)
  Future<void> _dispatchTask(
    DioClient client,
    UserSession acc,
    List<Map<String, dynamic>> courses,
  ) async {
    switch (_taskType) {
      case kTaskReport:
        await _doReport(client, acc, courses);
        break;
      case kTaskAnswers:
        await _doAnswers(client, acc, courses);
        break;
      case kTaskDownloadVideo:
        await _doDownload(client, acc, courses, 'video');
        break;
      case kTaskDownloadPaper:
        await _doDownload(client, acc, courses, 'paper');
        break;
      default:
        throw Exception('未知任务类型: $_taskType');
    }
  }

  /// 进度上报 (对齐 Python `_do_report`)
  ///
  /// 对齐 Python: TaskFactory.create("player_behavior", client, token, config)
  /// → 创建 PlayerBehaviorTask 执行完整播放行为模拟 (心跳/快刷/遥测)
  /// Flutter 对应: ProgressReportService (filterCourses → executeBatch)
  Future<void> _doReport(
    DioClient client,
    UserSession acc,
    List<Map<String, dynamic>> courses,
  ) async {
    // 使用调用方传入的 reportConfig (对齐 Python: cfg = self._config)
    // 若未传入则使用默认值
    final cfg = reportConfig ?? const ReportConfig();
    final token = acc.token;

    _log('  [50%] 开始进度上报 (对齐 Python player_behavior)',
        accountToken: token);
    _log('    配置: filterCompleted=${cfg.filterCompleted}, '
        'filterSeriousCheckChecked=${cfg.filterSeriousCheckChecked}, '
        'types=${cfg.selectedTypes}, subjects=${cfg.selectedSubjects.isEmpty ? "(全部)" : cfg.selectedSubjects.length}个, '
        'heartbeat=${cfg.heartbeatInterval}s, speed=${cfg.speed}x, '
        'fastBrush=${cfg.fastBrush}, useBackup=${cfg.useBackup}',
        accountToken: token);

    final service = ProgressReportService(
      client: client,
      endpointConfig: _endpointConfig,
      userSession: acc,
    );
    final logSub = service.logStream.listen((e) => _log('    ${e.message}',
        level: e.level, accountToken: token));

    try {
      // 过滤课程 (对齐 Python: filtered = self._filter_courses(all_courses))
      final tasks = service.filterCourses(
        courses,
        cfg,
        '', // homeworkId: 各课程自带, 传空
        schoolId: acc.schoolId,
      );

      _log('  过滤前课程数: ${courses.length}, 过滤后: ${tasks.length}',
          accountToken: token);
      if (tasks.isEmpty) {
        _log('  过滤后无可上报课程, 跳过此账号',
            level: LogLevel.warning, accountToken: token);
        return;
      }

      _updateState(token, _states[token]!.copyWith(
        status: BatchStatus.running,
        totalCourses: tasks.length,
        processedCourses: 0,
        message: '开始上报 ${tasks.length} 个课程',
      ));

      // 执行批量上报 (对齐 Python: task.execute())
      await service.executeBatch(
        tasks,
        cfg,
        onItemUpdate: (index, item) {
          if (_stopped || _disposed) return;
          _updateProgress(acc.token, index + 1, tasks.length);
          _log('    [${index + 1}/${tasks.length}] ${item.title} - '
              '${item.message ?? item.state.name}',
              level: item.state == PlaybackState.failed
                  ? LogLevel.error
                  : LogLevel.info,
              accountToken: token);
        },
      );
    } finally {
      await logSub.cancel();
      service.dispose();
    }
  }

  /// 试题答案 (对齐 Python `_do_answers`)
  ///
  /// 对齐 Python:
  ///   1. TaskFactory.create("course_batch", mode="answers") → 获取各课程答案
  ///   2. 按"获取完成操作"配置自动提交 / 自动导出 (每课程单独 / 全部合并)
  /// Flutter 对应:
  ///   1. `AnswerService.executeBatch` → `List<CourseAnswerResult>`
  ///   2. `AnswerSubmitHelper.submitResults` / `AnswerExportHelper.exportResults`
  Future<void> _doAnswers(
    DioClient client,
    UserSession acc,
    List<Map<String, dynamic>> courses,
  ) async {
    final service = AnswerService(client: client);
    final token = acc.token;
    final logSub = service.logStream.listen((e) => _log('    ${e.message}',
        level: e.level, accountToken: token));

    try {
      final homeworkId = courses.isNotEmpty
          ? (courses.first['homeworkId']?.toString() ?? '')
          : '';

      // 1. 获取所有课程答案 (对齐 Python: course_batch mode=answers)
      final results = await service.executeBatch(
        courses,
        homeworkId: homeworkId,
        schoolId: acc.schoolId,
        method: 'direct',
        filterConfig: answerFilterConfig,
        onItemUpdate: (index, item) {
          if (_stopped || _disposed) return;
          _updateProgress(acc.token, index + 1, courses.length);
          _log('    [${item.title}] ${item.message ?? ''}',
              level: item.state == PlaybackState.failed
                  ? LogLevel.error
                  : LogLevel.info,
              accountToken: token);
        },
      );

      if (_stopped || _disposed) return;
      if (results.isEmpty) {
        _log('  未获取到答案数据', accountToken: token);
        return;
      }

      // 1.5 获取完成操作: 按预配置自动提交 / 自动导出 (单选, 无操作则跳过)
      final accountName = acc.displayName ?? acc.account ?? acc.userId;
      final submitType = answerConfig?.submitType;
      final exportMode = answerConfig?.exportMode;
      if (submitType != null) {
        _log('  获取完成操作: ${answerConfig!.completeAction.label}...',
            accountToken: token);
        final summary = await AnswerSubmitHelper.submitResults(
          client: client,
          results: results,
          type: submitType,
          questionTypes: answerConfig?.submitQuestionTypes ?? const {},
          imageUploadConfig: answerConfig?.imageUploadConfig,
          onLog: (msg, lv) =>
              _log('    $msg', level: lv, accountToken: token),
        );
        _log('  自动提交完成: 成功 ${summary.success}, 失败 ${summary.fail}',
            level: summary.fail == 0 ? LogLevel.success : LogLevel.warning,
            accountToken: token);
      } else if (exportMode != null) {
        _log('  获取完成操作: ${answerConfig!.completeAction.label} '
            '(${results.length} 个课程)...', accountToken: token);
        final summary = await AnswerExportHelper.exportResults(
          results: results,
          mode: exportMode,
          prefix: '$accountName-',
        );
        final label = exportMode == AnswerExportMode.all ? '合并导出' : '每课程导出';
        _log('  $label完成: 成功 ${summary.success}, 失败 ${summary.fail}',
            level: summary.fail == 0 ? LogLevel.success : LogLevel.warning,
            accountToken: token);
      } else {
        _log('  获取完成操作: 无操作 (不提交不导出)', accountToken: token);
      }
    } finally {
      await logSub.cancel();
      service.dispose();
    }
  }

  /// 下载视频/试题 (对齐 Python `_do_download`)
  ///
  /// 对齐 Python: TaskFactory.create("course_download", mode=video/paper)
  /// Flutter 对应: DownloadService.downloadVideos / downloadPapers
  Future<void> _doDownload(
    DioClient client,
    UserSession acc,
    List<Map<String, dynamic>> courses,
    String mode,
  ) async {
    final service = DownloadService(client: client);
    final token = acc.token;
    final logSub = service.logStream.listen((e) => _log('    ${e.message}',
        level: e.level, accountToken: token));

    try {
      final homeworkId = courses.isNotEmpty
          ? (courses.first['homeworkId']?.toString() ?? '')
          : '';

      // 应用下载配置中的课程级过滤 (复用 AnswerService.applyFilter)
      final filterCfg = downloadConfig?.filterConfig;
      final filtered = filterCfg != null
          ? AnswerService.applyFilter(courses, filterCfg)
          : courses;
      _log('    过滤前: ${courses.length}, 过滤后: ${filtered.length}',
          accountToken: token);

      if (filtered.isEmpty) {
        _log('  过滤后无可下载课程',
            level: LogLevel.warning, accountToken: token);
        return;
      }

      if (mode == 'video') {
        await service.downloadVideos(
          filtered,
          homeworkId: homeworkId,
          schoolId: acc.schoolId,
          line: downloadConfig?.videoLine ?? VideoLine.auto,
          onItemUpdate: (index, item) {
            if (_stopped || _disposed) return;
            _updateProgress(acc.token, index + 1, filtered.length);
            _log('    [${item.title}] ${item.message ?? ''}',
                level: item.state == PlaybackState.failed
                    ? LogLevel.error
                    : LogLevel.info,
                accountToken: token);
          },
        );
      } else {
        await service.downloadPapers(
          filtered,
          homeworkId: homeworkId,
          schoolId: acc.schoolId,
          onItemUpdate: (index, item) {
            if (_stopped || _disposed) return;
            _updateProgress(acc.token, index + 1, filtered.length);
            _log('    [${item.title}] ${item.message ?? ''}',
                level: item.state == PlaybackState.failed
                    ? LogLevel.error
                    : LogLevel.info,
                accountToken: token);
          },
        );
      }
    } finally {
      await logSub.cancel();
      service.dispose();
    }
  }

  void _updateProgress(String token, int processed, int total) {
    final s = _states[token];
    if (s == null) return;
    _updateState(token, s.copyWith(
      status: BatchStatus.running,
      totalCourses: total,
      processedCourses: processed,
      message: '$processed/$total',
    ));
  }

  /// 停止
  void stop() {
    _stopped = true;
    _log('收到停止信号, 将在当前操作完成后退出', level: LogLevel.warning);
  }

  /// 释放
  void dispose() {
    _stopped = true;
    _disposed = true;
    if (!_logController.isClosed) _logController.close();
    if (!_stateController.isClosed) _stateController.close();
  }
}

/// 批量任务状态
enum BatchStatus { pending, running, done, failed }

/// 单账号在批量任务中的状态
class AccountBatchState {
  final UserSession account;
  final BatchStatus status;
  final int totalCourses;
  final int processedCourses;
  final String message;

  /// 该账号任务开始时间 (进入 running 时记录, 供详情页展示耗时)
  final DateTime? startedAt;

  AccountBatchState({
    required this.account,
    required this.status,
    required this.totalCourses,
    required this.processedCourses,
    required this.message,
    this.startedAt,
  });

  /// 进度百分比 (0.0 ~ 1.0)
  double get progress =>
      totalCourses > 0 ? processedCourses / totalCourses : 0.0;

  /// 已耗时 (开始时间已知时)
  Duration? get elapsed {
    final s = startedAt;
    if (s == null) return null;
    if (status == BatchStatus.done || status == BatchStatus.failed) {
      return DateTime.now().difference(s);
    }
    return DateTime.now().difference(s);
  }

  AccountBatchState copyWith({
    UserSession? account,
    BatchStatus? status,
    int? totalCourses,
    int? processedCourses,
    String? message,
    DateTime? startedAt,
    bool clearStartedAt = false,
  }) {
    return AccountBatchState(
      account: account ?? this.account,
      status: status ?? this.status,
      totalCourses: totalCourses ?? this.totalCourses,
      processedCourses: processedCourses ?? this.processedCourses,
      message: message ?? this.message,
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
    );
  }
}
