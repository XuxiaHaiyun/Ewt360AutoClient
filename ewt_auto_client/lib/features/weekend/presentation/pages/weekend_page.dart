/// 周培优主页面：班级/教材/章节任务视图与任务列表双模式展示，支持任务多选
/// 批量上报/下载、视频播放与周练错题解析（答案获取/提交/PDF 预览）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/layout/app_breakpoints.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/risk_control/risk_control_gate.dart';
import '../../../../core/widgets/context_menu_region.dart';
import '../../../../shared/utils/app_feedback.dart';
import '../../../answer/domain/entities/answer_config.dart';
import '../../../answer/presentation/pages/answer_pdf_preview_page.dart';
import '../../../answer/presentation/pages/answer_result_page.dart';
import '../../../answer/presentation/services/answer_service.dart';
import '../../../answer/presentation/services/submit_paper_helper.dart';
import '../pages/weekend_answer_config_page.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../download/presentation/services/download_service.dart';
import '../../../download/presentation/dialogs/download_config_dialog.dart';
import '../../../player/data/datasources/player_remote_datasource.dart';
import '../../../player/domain/services/video_source_resolver.dart';
import '../../../player/presentation/pages/report_config_page.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../../player/presentation/services/progress_report_service.dart';
import '../../../player/presentation/services/video_play_launcher.dart';
import '../../data/datasources/weekend_remote_datasource.dart';
import '../dialogs/weekend_task_detail_dialog.dart';
import '../providers/weekend_provider.dart';

/// 学科颜色映射
const _subjectColors = <String, Color>{
  '语文': Color(0xFFE74C3C),
  '数学': Color(0xFF3498DB),
  '英语': Color(0xFF2ECC71),
  '物理': Color(0xFF9B59B6),
  '化学': Color(0xFFF39C12),
  '生物': Color(0xFF1ABC9C),
  '政治': Color(0xFFE67E22),
  '历史': Color(0xFF795548),
  '地理': Color(0xFF00BCD4),
};

Color _colorForSubject(String? subject) {
  if (subject == null) return const Color(0xFF607D8B);
  for (final entry in _subjectColors.entries) {
    if (subject.contains(entry.key)) return entry.value;
  }
  return const Color(0xFF607D8B);
}

/// 周培优页面
///
/// 对应 Python: gui/interfaces/weekly.py
class WeekendPage extends ConsumerStatefulWidget {
  const WeekendPage({super.key});

  @override
  ConsumerState<WeekendPage> createState() => _WeekendPageState();
}

class _WeekendPageState extends ConsumerState<WeekendPage> {
  /// 任务视图多选模式
  bool _selectable = false;
  Set<int> _selectedIndices = {};

  // 章节列表多选 (viewMode == 'chapters')
  bool _chapterSelectable = false;
  Set<int> _selectedChapterIndices = {};

  // ─── 周练错题解析状态 ───
  /// 当前已加载数据对应的 "班级ID|章节ID"
  ///
  /// 切换班级/教材/章节时该 key 会变化, 用于自动重新拉取并丢弃过期响应,
  /// 避免继续展示上一个章节的 paperId / 错题列表。
  String? _wrongQuestionKey;
  Map<String, dynamic> _wrongQuestionDetail = {};
  bool _wrongQuestionLoading = false;
  String? _wrongQuestionError;

  /// 周练错题解析卡片是否展开 (默认收起)
  bool _wrongQuestionExpanded = false;

  /// 正在加载视频源的错题 (lessonId), 用于点击播放时显示 loading
  String? _wrongQuestionPlaying;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(weekendProvider.notifier).loadUserInfo();
    });
  }

  // ─── 操作 ───

  void _executeAction(Map<String, dynamic> task, String action) {
    if (action == 'report') {
      _startProgressReport([task]);
      return;
    }
    if (action == 'answers') {
      _startAnswerFetch([task]);
      return;
    }
    if (action == 'submit_paper') {
      _executeSubmitPaper([task]);
      return;
    }
    if (action.startsWith('download_')) {
      _startDownload([task], action);
      return;
    }
    final title = task['taskTitle']?.toString() ??
        task['taskName']?.toString() ??
        task['name']?.toString() ??
        task['title']?.toString() ??
        '任务';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('[$title] ${_actionLabel(action)} - 功能开发中'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _openTaskDetail(Map<String, dynamic> task) {
    final state = ref.read(weekendProvider);
    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    showDialog(
      context: context,
      builder: (_) => WeekendTaskDetailDialog(
        taskData: task,
        chapterName: state.currentChapterName ?? '',
        chapterId: state.currentChapterId ?? '',
        classId: state.selectedClassId ?? '',
        userSession: session,
      ),
    );
  }

  void _batchAction(String action) {
    if (action == 'report') {
      final state = ref.read(weekendProvider);
      final selectedTasks = _selectedIndices
          .where((i) => i < state.tasks.length)
          .map((i) => state.tasks[i] as Map<String, dynamic>)
          .toList();
      if (selectedTasks.isNotEmpty) {
        _startProgressReport(selectedTasks);
      }
      setState(() {
        _selectable = false;
        _selectedIndices.clear();
      });
      return;
    }
    if (action == 'answers') {
      final state = ref.read(weekendProvider);
      final selectedTasks = _selectedIndices
          .where((i) => i < state.tasks.length)
          .map((i) => state.tasks[i] as Map<String, dynamic>)
          .toList();
      if (selectedTasks.isNotEmpty) {
        _startAnswerFetch(selectedTasks);
      }
      setState(() {
        _selectable = false;
        _selectedIndices.clear();
      });
      return;
    }
    if (action == 'submit_paper') {
      final state = ref.read(weekendProvider);
      final selectedTasks = _selectedIndices
          .where((i) => i < state.tasks.length)
          .map((i) => state.tasks[i] as Map<String, dynamic>)
          .toList();
      if (selectedTasks.isNotEmpty) {
        _executeSubmitPaper(selectedTasks);
      }
      setState(() {
        _selectable = false;
        _selectedIndices.clear();
      });
      return;
    }
    if (action.startsWith('download_')) {
      final state = ref.read(weekendProvider);
      final selectedTasks = _selectedIndices
          .where((i) => i < state.tasks.length)
          .map((i) => state.tasks[i] as Map<String, dynamic>)
          .toList();
      if (selectedTasks.isNotEmpty) {
        _startDownload(selectedTasks, action);
      }
      setState(() {
        _selectable = false;
        _selectedIndices.clear();
      });
      return;
    }
    final count = _selectedIndices.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已选 $count 个任务 → ${_actionLabel(action)} - 功能开发中'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ─── 章节级操作 (拉取章节下所有任务后执行) ───

  /// 单章节操作: 拉取该章节下所有任务 → 执行
  Future<void> _executeChapterAction(
      Map<String, dynamic> chapter, String action) async {
    final chapterName = chapter['chapterName']?.toString() ??
        chapter['name']?.toString() ??
        '未知章节';

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('[$chapterName] 正在加载任务列表...'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
        ),
      );
    }

    final tasks =
        await ref.read(weekendProvider.notifier).fetchTasksForChapter(chapter);
    if (tasks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('[$chapterName] 未找到任务'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    if (action == 'report') {
      await _startProgressReport(tasks);
    } else if (action == 'answers') {
      await _startAnswerFetch(tasks);
    } else if (action.startsWith('download_')) {
      await _startDownload(tasks, action);
    }
  }

  /// 多章节批量操作: 拉取所有选中章节的任务 → 合并 → 执行
  Future<void> _batchChapterAction(String action) async {
    final state = ref.read(weekendProvider);
    final selectedChapters = _selectedChapterIndices
        .where((i) => i < state.currentChapters.length)
        .map((i) => state.currentChapters[i] as Map<String, dynamic>)
        .toList();

    // 先退出多选, 避免阻塞 UI
    setState(() {
      _chapterSelectable = false;
      _selectedChapterIndices.clear();
    });

    if (selectedChapters.isEmpty) return;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '正在加载 ${selectedChapters.length} 个章节的任务列表...'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 1),
        ),
      );
    }

    // 并行拉取所有选中章节的任务, 合并
    final results = await Future.wait(
      selectedChapters
          .map((ch) => ref.read(weekendProvider.notifier).fetchTasksForChapter(ch)),
    );
    final allTasks = <Map<String, dynamic>>[];
    for (final list in results) {
      allTasks.addAll(list);
    }

    if (allTasks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('选中章节下未找到任务'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    if (action == 'report') {
      await _startProgressReport(allTasks);
    } else if (action == 'answers') {
      await _startAnswerFetch(allTasks);
    } else if (action.startsWith('download_')) {
      await _startDownload(allTasks, action);
    }
  }

  /// 启动进度上报流程（周培优任务）
  Future<void> _startProgressReport(
      List<Map<String, dynamic>> tasks) async {
    // 1. 打开配置页
    final config = await ReportConfigPage.show(context);
    if (config == null || !mounted) return;

    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    final schoolId = session?.schoolId ?? '';

    // 2. 从周培优任务构建 ReportTask 列表
    final reportTasks = <ReportTask>[];
    for (final task in tasks) {
      // 过滤已完成
      if (config.filterCompleted) {
        final complete = task['lessonIsComplete'] == true ||
            task['lessonIsComplete'] == 1 ||
            task['paperIsComplete'] == true ||
            task['paperIsComplete'] == 1;
        if (complete) continue;
      }

      final lessonId = task['lessonId']?.toString() ??
          task['id']?.toString() ??
          '';
      if (lessonId.isEmpty) continue;

      final title = task['taskTitle']?.toString() ??
          task['title']?.toString() ??
          task['name']?.toString() ??
          '未知任务';
      final videoId = task['videoId']?.toString() ?? '';
      final taskId = task['taskId']?.toString() ??
          task['task_id']?.toString() ??
          '';
      final contentType = task['contentType'] is int
          ? task['contentType'] as int
          : int.tryParse(task['contentType']?.toString() ?? '') ;

      reportTasks.add(ReportTask(
        title: title,
        homeworkId: '', // 周培优无 homeworkId
        lessonId: lessonId,
        videoId: videoId,
        schoolId: schoolId,
        taskId: taskId,
        contentType: contentType,
        subjectName: task['subjectName']?.toString() ?? '',
        duration: 0,
      ));
    }

    if (reportTasks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('没有符合条件的任务需要上报'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // 3. 创建服务
    final service = ProgressReportService(
      client: getIt<DioClient>(),
      endpointConfig: getIt<EndpointConfig>(),
      userSession: session,
    );

    // 4. 构建进度项
    final items = reportTasks
        .map((t) => TaskProgressItem(title: t.title, subtitle: t.lessonId))
        .toList();

    // 5. 显示进度弹窗
    if (!mounted) return;
    TaskProgressDialog.show(
      context,
      items: items,
      logStream: service.logStream,
      title: '进度上报',
      progressPoller: config.realProgressQuery
          ? () => service.queryRealProgress(reportTasks)
          : null,
      progressPollInterval: config.progressPollInterval,
      completionThreshold: config.completionThreshold,
      sessionStream: service.sessionStream,
      engineStateStream: service.engineStateStream,
      onStop: () {
        service.cancel();
        service.dispose();
      },
    );

    // 6. 执行批量上报
    await service.executeBatch(
      reportTasks,
      config,
      onItemUpdate: (index, item) {
        if (index < items.length) {
          items[index].state = item.state;
          items[index].progress = item.progress;
          items[index].message = item.message;
          items[index].error = item.error;
        }
      },
    );

    service.dispose();
  }

  /// 启动试题答案获取流程（周培优任务）
  Future<void> _startAnswerFetch(
      List<Map<String, dynamic>> tasks) async {
    // 周培优专用配置页 (仅方案 + 展示字段, 无作业场景的过滤选项)
    final config = await WeekendAnswerConfigPage.show(context);
    if (config == null || !mounted) return;

    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    final schoolId = session?.schoolId ?? '';

    // 周培优任务无 homeworkId/taskId/subjectName 等字段,
    // 作业场景的过滤选项不适用, 直接使用原始任务列表
    if (tasks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有可获取答案的任务')),
        );
      }
      return;
    }

    // ─── 下载方案: 不逐题获取答案, 由服务端生成教师版试卷 PDF, 在预览页打开 ───
    if (config.method == AnswerMethod.download) {
      final service = DownloadService(client: getIt<DioClient>());
      final dialogKey = GlobalKey<TaskProgressDialogState>();

      final items = tasks
          .map((t) => TaskProgressItem(
                title: (t['taskTitle'] ?? t['title'] ?? t['name'] ?? '任务')
                    .toString(),
                subtitle: (t['lessonId'] ?? t['contentId'] ?? '').toString(),
              ))
          .toList();

      if (!mounted) return;
      var dialogDismissed = false;
      TaskProgressDialog.show(
        context,
        items: items,
        logStream: service.logStream,
        title: '试题答案获取',
        dialogKey: dialogKey,
        onStop: () {
          dialogDismissed = true;
          service.cancel();
          service.dispose();
        },
      );

      // 下载教师版 PDF 预览 (type=teacher, 不写盘, 返回内存字节)
      final previews = await service.downloadAnswerPreviews(
        tasks,
        homeworkId: '',
        schoolId: schoolId,
        onItemUpdate: (index, item) {
          if (index < items.length) {
            items[index].state = item.state;
            items[index].progress = item.progress;
            items[index].message = item.message;
            items[index].error = item.error;
          }
        },
      );

      service.dispose();

      if (!dialogDismissed) {
        dialogKey.currentState?.markFinished();
        if (mounted && previews.isNotEmpty) {
          await AnswerPdfPreviewPage.push(context, items: previews);
        }
      }
      return;
    }

    final service = AnswerService(client: getIt<DioClient>());
    final dialogKey = GlobalKey<TaskProgressDialogState>();

    // 构建进度项
    final items = tasks
        .map((t) => TaskProgressItem(
              title: (t['taskTitle'] ?? t['title'] ?? t['name'] ?? '任务')
                  .toString(),
              subtitle: (t['lessonId'] ?? t['contentId'] ?? '').toString(),
            ))
        .toList();

    // 显示进度弹窗
    if (!mounted) return;
    var dialogDismissed = false;
    TaskProgressDialog.show(
      context,
      items: items,
      logStream: service.logStream,
      title: '试题答案获取',
      dialogKey: dialogKey,
      onStop: () {
        dialogDismissed = true;
        service.cancel();
        service.dispose();
      },
    );

    // 执行批量获取 (周培优无 homeworkId, 不过滤)
    final results = await service.executeBatch(
      tasks,
      homeworkId: '',
      schoolId: schoolId,
      method: config.method.value,
      onItemUpdate: (index, item) {
        if (index < items.length) {
          items[index].state = item.state;
          items[index].progress = item.progress;
          items[index].message = item.message;
          items[index].error = item.error;
        }
      },
    );

    service.dispose();

    // 不关闭弹窗: 标记完成, 直接进入答案页, 方便返回查看日志
    if (!dialogDismissed) {
      dialogKey.currentState?.markFinished();
      if (mounted && results.isNotEmpty) {
        AnswerResultPage.push(context, results: results, displayConfig: config);
      }
    }
  }

  /// 启动"提交试卷": 获取试卷 → 手动填写答案/上传图片 → 提交作答结果 (周培优无 homeworkId)
  Future<void> _executeSubmitPaper(
      List<Map<String, dynamic>> tasks) async {
    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    if (tasks.isEmpty) return;
    await SubmitPaperHelper.run(
      context,
      tasks,
      homeworkId: '',
      schoolId: session?.schoolId ?? '',
    );
  }

  /// 启动下载流程 (导学案/视频/试题)
  Future<void> _startDownload(
      List<Map<String, dynamic>> tasks, String action) async {
    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    final schoolId = session?.schoolId ?? '';

    // 下载视频: 先弹出线路选择 (自动/腾讯云/阿里云), 取消则终止
    VideoLine videoLine = VideoLine.auto;
    if (action == 'download_video') {
      final cfg = await DownloadConfigDialog.show(context, mode: 'video');
      if (cfg == null || !mounted) return;
      videoLine = cfg.videoLine;
    }

    final service = DownloadService(client: getIt<DioClient>());
    final dialogKey = GlobalKey<TaskProgressDialogState>();

    final items = tasks
        .map((t) => TaskProgressItem(
              title: (t['taskTitle'] ?? t['title'] ?? t['name'] ?? '任务')
                  .toString(),
              subtitle: (t['lessonId'] ?? t['contentId'] ?? '').toString(),
            ))
        .toList();

    if (!mounted) return;
    TaskProgressDialog.show(
      context,
      items: items,
      logStream: service.logStream,
      title: _actionLabel(action),
      dialogKey: dialogKey,
      onStop: () {
        service.cancel();
        service.dispose();
      },
    );

    void onItemUpdate(int index, TaskProgressItem item) {
      if (index < items.length) {
        items[index].state = item.state;
        items[index].progress = item.progress;
        items[index].message = item.message;
        items[index].error = item.error;
      }
    }

    switch (action) {
      case 'download_guide':
        await service.downloadGuides(tasks,
            homeworkId: '', schoolId: schoolId,
            onItemUpdate: onItemUpdate);
      case 'download_video':
        await service.downloadVideos(tasks,
            homeworkId: '', schoolId: schoolId,
            line: videoLine,
            onItemUpdate: onItemUpdate);
      case 'download_paper':
        await service.downloadPapers(tasks,
            homeworkId: '', schoolId: schoolId,
            onItemUpdate: onItemUpdate);
      default:
        break;
    }

    service.dispose();

    // 标记完成: 弹窗按钮从"停止"变为"关闭", 用户可查看日志后手动关闭
    dialogKey.currentState?.markFinished();
  }

  String _actionLabel(String action) {
    return switch (action) {
      'report' => '进度上报',
      'answers' => '试题答案',
      'submit_paper' => '提交试卷',
      'download_paper' => '下载试题',
      'download_video' => '下载视频',
      'download_guide' => '下载导学案',
      _ => action,
    };
  }

  /// 批量任务选择弹窗
  void _showBatchActionDialog() {
    final theme = Theme.of(context);
    final actions = <(String, String, IconData)>[
      ('report', '进度上报', Icons.upload_outlined),
      ('answers', '试题答案', Icons.quiz_outlined),
      ('submit_paper', '提交试卷', Icons.task_alt_outlined),
      ('download_paper', '下载试题', Icons.description_outlined),
      ('download_video', '下载视频', Icons.video_file_outlined),
      ('download_guide', '下载导学案', Icons.menu_book_outlined),
    ];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '批量执行 (${_selectedIndices.length} 项)',
          style: theme.textTheme.titleMedium,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (action, label, icon) in actions)
              ListTile(
                leading: Icon(icon, size: 22),
                title: Text(label),
                dense: true,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _batchAction(action);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 章节批量任务选择弹窗
  void _showChapterBatchActionDialog() {
    final theme = Theme.of(context);
    final actions = <(String, String, IconData)>[
      ('report', '进度上报', Icons.upload_outlined),
      ('answers', '试题答案', Icons.quiz_outlined),
      ('submit_paper', '提交试卷', Icons.task_alt_outlined),
      ('download_paper', '下载试题', Icons.description_outlined),
      ('download_video', '下载视频', Icons.video_file_outlined),
      ('download_guide', '下载导学案', Icons.menu_book_outlined),
    ];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '批量执行 (${_selectedChapterIndices.length} 个章节)',
          style: theme.textTheme.titleMedium,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (action, label, icon) in actions)
              ListTile(
                leading: Icon(icon, size: 22),
                title: Text(label),
                dense: true,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _batchChapterAction(action);
                },
              ),
          ],
        ),
      ),
    );
  }

  List<ContextMenuItem> _actionMenuItems({
    required void Function(String action) onAction,
  }) {
    return [
      ContextMenuItem(
        id: 'report',
        label: '进度上报',
        icon: Icons.upload_outlined,
        enabled: RiskControlGate.isFeatureEnabled('weekend_menu.report'),
        onTap: () => onAction('report'),
      ),
      ContextMenuItem(
        id: 'answers',
        label: '试题答案',
        icon: Icons.quiz_outlined,
        enabled: RiskControlGate.isFeatureEnabled('weekend_menu.answers'),
        onTap: () => onAction('answers'),
      ),
      ContextMenuItem(
        id: 'submit_paper',
        label: '提交试卷',
        icon: Icons.task_alt_outlined,
        enabled: RiskControlGate.isFeatureEnabled('weekend_menu.submit_paper'),
        onTap: () => onAction('submit_paper'),
      ),
      const ContextMenuItem.divider(),
      ContextMenuItem(
        id: 'download_paper',
        label: '下载试题',
        icon: Icons.description_outlined,
        enabled: RiskControlGate.isFeatureEnabled('weekend_menu.download_paper'),
        onTap: () => onAction('download_paper'),
      ),
      ContextMenuItem(
        id: 'download_video',
        label: '下载视频',
        icon: Icons.video_file_outlined,
        enabled: RiskControlGate.isFeatureEnabled('weekend_menu.download_video'),
        onTap: () => onAction('download_video'),
      ),
      ContextMenuItem(
        id: 'download_guide',
        label: '下载导学案',
        icon: Icons.menu_book_outlined,
        enabled: RiskControlGate.isFeatureEnabled('weekend_menu.download_guide'),
        onTap: () => onAction('download_guide'),
      ),
    ];
  }

  List<ContextMenuItem> _multiSelectMenuItems() {
    final hasSelection = _selectedIndices.isNotEmpty;
    final multiOk = RiskControlGate.isFeatureEnabled('weekend_menu.multi_select');
    return [
      ContextMenuItem(
        id: 'exit_multi',
        label: '退出多选',
        icon: Icons.close_outlined,
        enabled: multiOk,
        onTap: () => setState(() {
          _selectable = false;
          _selectedIndices.clear();
        }),
      ),
      ContextMenuItem(
        id: 'select_all',
        label: '全选 / 取消全选',
        icon: Icons.select_all_outlined,
        enabled: multiOk,
        onTap: () {
          final state = ref.read(weekendProvider);
          setState(() {
            if (_selectedIndices.length == state.tasks.length) {
              _selectedIndices.clear();
            } else {
              _selectedIndices =
                  List.generate(state.tasks.length, (i) => i).toSet();
            }
          });
        },
      ),
      ContextMenuItem(
        id: 'invert',
        label: '反选',
        icon: Icons.flip_outlined,
        enabled: multiOk,
        onTap: () {
          final state = ref.read(weekendProvider);
          setState(() {
            final all = List.generate(state.tasks.length, (i) => i).toSet();
            _selectedIndices = all.difference(_selectedIndices);
          });
        },
      ),
      const ContextMenuItem.divider(),
      ContextMenuItem(
        id: 'report',
        label: '进度上报',
        icon: Icons.upload_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.report'),
        onTap: () => _batchAction('report'),
      ),
      ContextMenuItem(
        id: 'answers',
        label: '试题答案',
        icon: Icons.quiz_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.answers'),
        onTap: () => _batchAction('answers'),
      ),
      ContextMenuItem(
        id: 'submit_paper',
        label: '提交试卷',
        icon: Icons.task_alt_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.submit_paper'),
        onTap: () => _batchAction('submit_paper'),
      ),
      const ContextMenuItem.divider(),
      ContextMenuItem(
        id: 'download_paper',
        label: '下载试题',
        icon: Icons.description_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.download_paper'),
        onTap: () => _batchAction('download_paper'),
      ),
      ContextMenuItem(
        id: 'download_video',
        label: '下载视频',
        icon: Icons.video_file_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.download_video'),
        onTap: () => _batchAction('download_video'),
      ),
      ContextMenuItem(
        id: 'download_guide',
        label: '下载导学案',
        icon: Icons.menu_book_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.download_guide'),
        onTap: () => _batchAction('download_guide'),
      ),
    ];
  }

  /// 章节多选模式菜单项 (与任务多选菜单结构一致)
  List<ContextMenuItem> _chapterMultiSelectMenuItems() {
    final hasSelection = _selectedChapterIndices.isNotEmpty;
    final multiOk = RiskControlGate.isFeatureEnabled('weekend_menu.multi_select');
    return [
      ContextMenuItem(
        id: 'exit_multi',
        label: '退出多选',
        icon: Icons.close_outlined,
        enabled: multiOk,
        onTap: () => setState(() {
          _chapterSelectable = false;
          _selectedChapterIndices.clear();
        }),
      ),
      ContextMenuItem(
        id: 'select_all',
        label: '全选 / 取消全选',
        icon: Icons.select_all_outlined,
        enabled: multiOk,
        onTap: () {
          final state = ref.read(weekendProvider);
          final total = state.currentChapters.length;
          setState(() {
            if (_selectedChapterIndices.length == total) {
              _selectedChapterIndices.clear();
            } else {
              _selectedChapterIndices =
                  List.generate(total, (i) => i).toSet();
            }
          });
        },
      ),
      ContextMenuItem(
        id: 'invert',
        label: '反选',
        icon: Icons.flip_outlined,
        enabled: multiOk,
        onTap: () {
          final state = ref.read(weekendProvider);
          final total = state.currentChapters.length;
          setState(() {
            final all = List.generate(total, (i) => i).toSet();
            _selectedChapterIndices = all.difference(_selectedChapterIndices);
          });
        },
      ),
      const ContextMenuItem.divider(),
      ContextMenuItem(
        id: 'report',
        label: '进度上报',
        icon: Icons.upload_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.report'),
        onTap: () => _batchChapterAction('report'),
      ),
      ContextMenuItem(
        id: 'answers',
        label: '试题答案',
        icon: Icons.quiz_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.answers'),
        onTap: () => _batchChapterAction('answers'),
      ),
      const ContextMenuItem.divider(),
      ContextMenuItem(
        id: 'download_paper',
        label: '下载试题',
        icon: Icons.description_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.download_paper'),
        onTap: () => _batchChapterAction('download_paper'),
      ),
      ContextMenuItem(
        id: 'download_video',
        label: '下载视频',
        icon: Icons.video_file_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.download_video'),
        onTap: () => _batchChapterAction('download_video'),
      ),
      ContextMenuItem(
        id: 'download_guide',
        label: '下载导学案',
        icon: Icons.menu_book_outlined,
        enabled: hasSelection && RiskControlGate.isFeatureEnabled('weekend_menu.download_guide'),
        onTap: () => _batchChapterAction('download_guide'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(weekendProvider);
    final theme = Theme.of(context);
    final isWide = !context.isNarrow;

    return Scaffold(
      appBar: AppBar(
        leading: _selectable
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selectable = false;
                  _selectedIndices.clear();
                }),
              )
            : _chapterSelectable
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _chapterSelectable = false;
                      _selectedChapterIndices.clear();
                    }),
                  )
                : state.viewMode == 'tasks'
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () =>
                            ref.read(weekendProvider.notifier).backToChapters(),
                      )
                    : null,
        title: _selectable
            ? Text('已选 ${_selectedIndices.length} 项')
            : _chapterSelectable
                ? Text('已选 ${_selectedChapterIndices.length} 项')
                : Text(
                    state.viewMode == 'tasks'
                        ? (state.currentChapterName ?? '周培优')
                        : '周培优',
                  ),
        actions: _selectable
            ? [
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  tooltip: '运行',
                  onPressed: _selectedIndices.isNotEmpty
                      ? _showBatchActionDialog
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: '全选',
                  onPressed: () {
                    final st = ref.read(weekendProvider);
                    setState(() {
                      if (_selectedIndices.length == st.tasks.length) {
                        _selectedIndices.clear();
                      } else {
                        _selectedIndices =
                            List.generate(st.tasks.length, (i) => i).toSet();
                      }
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.flip),
                  tooltip: '反选',
                  onPressed: () {
                    final st = ref.read(weekendProvider);
                    setState(() {
                      final all =
                          List.generate(st.tasks.length, (i) => i).toSet();
                      _selectedIndices = all.difference(_selectedIndices);
                    });
                  },
                ),
              ]
            : _chapterSelectable
                ? [
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      tooltip: '运行',
                      onPressed: _selectedChapterIndices.isNotEmpty
                          ? _showChapterBatchActionDialog
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.select_all),
                      tooltip: '全选',
                      onPressed: () {
                        final st = ref.read(weekendProvider);
                        final total = st.currentChapters.length;
                        setState(() {
                          if (_selectedChapterIndices.length == total) {
                            _selectedChapterIndices.clear();
                          } else {
                            _selectedChapterIndices =
                                List.generate(total, (i) => i).toSet();
                          }
                        });
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.flip),
                      tooltip: '反选',
                      onPressed: () {
                        final st = ref.read(weekendProvider);
                        final total = st.currentChapters.length;
                        setState(() {
                          final all =
                              List.generate(total, (i) => i).toSet();
                          _selectedChapterIndices =
                              all.difference(_selectedChapterIndices);
                        });
                      },
                    ),
                  ]
                : [
                    IconButton(
                      icon: const Icon(Icons.menu_book),
                      tooltip: '教材库',
                      onPressed: () => context.push('/book-list'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: '刷新',
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await ref
                            .read(weekendProvider.notifier)
                            .refresh();
                        if (!context.mounted) return;
                        final st = ref.read(weekendProvider);
                        showAppSnackBar(
                          messenger,
                          st.error == null ? '刷新完成' : '刷新失败: ${st.error}',
                          isError: st.error != null,
                        );
                      },
                    ),
                  ],
      ),
      body: Column(
        children: [
          // 班级选择器
          if (state.classList.isNotEmpty) _buildClassSelector(state, theme),
          // 教材 tabs（仅章节视图显示）
          if (state.viewMode == 'chapters' && state.bookList.isNotEmpty)
            _buildBookTabs(state, theme),
          // 主内容区
          Expanded(
            child: _buildBody(state, theme, isWide),
          ),
        ],
      ),
    );
  }

  // ─── 班级选择器 ───────────────────────────────────────────────

  Widget _buildClassSelector(WeekendState state, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.groups_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: state.selectedClassId,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerLow,
              ),
              items: state.classList.map((c) {
                final map = c as Map<String, dynamic>;
                final id = map['classId']?.toString() ??
                    map['id']?.toString() ??
                    '';
                final name = map['className']?.toString() ??
                    map['name']?.toString() ??
                    '';
                return DropdownMenuItem(value: id, child: Text(name));
              }).toList(),
              onChanged: (value) {
                if (value == null) return;
                final cls = state.classList.firstWhere(
                  (c) =>
                      (c as Map<String, dynamic>)['classId']?.toString() ==
                          value ||
                      c['id']?.toString() == value,
                  orElse: () => null,
                );
                if (cls != null) {
                  final map = cls as Map<String, dynamic>;
                  final name = map['className']?.toString() ??
                      map['name']?.toString() ??
                      '';
                  ref.read(weekendProvider.notifier).selectClass(value, name);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─── 教材 Tabs ──────────────────────────────────────────────

  Widget _buildBookTabs(WeekendState state, ThemeData theme) {
    return SizedBox(
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: state.bookList.length,
        itemBuilder: (context, index) {
          final book = state.bookList[index] as Map<String, dynamic>;
          final bookName = book['bookName']?.toString() ??
              book['name']?.toString() ??
              '教材${index + 1}';
          final subjectName = book['subjectName']?.toString() ?? '';
          final isActive = index == state.activeBookIndex;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: ChoiceChip(
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (subjectName.isNotEmpty) ...[
                    Text(
                      subjectName,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isActive
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    bookName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
              selected: isActive,
              onSelected: (_) =>
                  ref.read(weekendProvider.notifier).selectBook(index),
              selectedColor: theme.colorScheme.primaryContainer,
              labelStyle: TextStyle(
                color: isActive
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          );
        },
      ),
    );
  }

  // ─── 主内容区 ───────────────────────────────────────────────

  Widget _buildBody(WeekendState state, ThemeData theme, bool isWide) {
    // 无权限状态
    if (state.hasAuth == false) {
      return _buildNoAccessView(theme);
    }

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null) {
      return _buildErrorView(state.error!, theme);
    }

    if (state.viewMode == 'tasks') {
      return _buildTaskList(state, theme, isWide);
    }

    return _buildChapterList(state, theme, isWide);
  }

  // ─── 错误视图 ───────────────────────────────────────────────

  Widget _buildErrorView(String message, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 56,
              color: theme.colorScheme.error.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              '加载失败',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              onPressed: () => ref.read(weekendProvider.notifier).refresh(),
            ),
          ],
        ),
      ),
    );
  }

  // ─── 无权限视图 ─────────────────────────────────────────────

  Widget _buildNoAccessView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              '暂无权限',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '当前账号未开通周培优服务',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color:
                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              onPressed: () => ref.read(weekendProvider.notifier).refresh(),
            ),
          ],
        ),
      ),
    );
  }

  // ─── 章节列表 ───────────────────────────────────────────────

  Widget _buildChapterList(WeekendState state, ThemeData theme, bool isWide) {
    final chapters = state.currentChapters;
    if (chapters.isEmpty) {
      return _buildEmptyView(
        icon: Icons.menu_book_outlined,
        title: '暂无章节',
        subtitle: '当前教材下没有章节数据',
        theme: theme,
      );
    }

    // 网格列数按宽度档位递增: 窄屏单列, 中屏双列, 大屏三列。
    final crossAxisCount = switch (context.windowSize) {
      WindowSize.compact => 1,
      WindowSize.medium => 2,
      _ => 3,
    };

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: isWide ? 4.5 : 5.0,
      ),
      itemCount: chapters.length,
      itemBuilder: (context, index) {
        final chapter = chapters[index] as Map<String, dynamic>;
        final chapterName = chapter['chapterName']?.toString() ??
            chapter['name']?.toString() ??
            '';

        return ContextMenuRegion(
          title: chapterName.length > 20
              ? '${chapterName.substring(0, 20)}...'
              : chapterName,
          menuBuilder: (_) => _chapterSelectable
              ? _chapterMultiSelectMenuItems()
              : [
                  ContextMenuItem(
                    id: 'enter',
                    label: '进入章节',
                    icon: Icons.open_in_new_outlined,
                    enabled: RiskControlGate.isFeatureEnabled('weekend_menu.enter_chapter'),
                    onTap: () =>
                        ref.read(weekendProvider.notifier).enterChapter(chapter),
                  ),
                  const ContextMenuItem.divider(),
                  ..._actionMenuItems(
                    onAction: (action) =>
                        _executeChapterAction(chapter, action),
                  ),
                  const ContextMenuItem.divider(),
                  ContextMenuItem(
                    id: 'multi_select',
                    label: '多选',
                    icon: Icons.checklist_outlined,
                    enabled: RiskControlGate.isFeatureEnabled('weekend_menu.multi_select'),
                    onTap: () {
                      setState(() {
                        _chapterSelectable = true;
                        _selectedChapterIndices.add(index);
                      });
                    },
                  ),
                ],
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _chapterSelectable
                ? () {
                    setState(() {
                      if (_selectedChapterIndices.contains(index)) {
                        _selectedChapterIndices.remove(index);
                      } else {
                        _selectedChapterIndices.add(index);
                      }
                    });
                  }
                : () => ref.read(weekendProvider.notifier).enterChapter(chapter),
            child: _ChapterCard(
              chapter: chapter,
              selectable: _chapterSelectable,
              selected: _selectedChapterIndices.contains(index),
              onToggleSelect: _chapterSelectable
                  ? () {
                      setState(() {
                        if (_selectedChapterIndices.contains(index)) {
                          _selectedChapterIndices.remove(index);
                        } else {
                          _selectedChapterIndices.add(index);
                        }
                      });
                    }
                  : null,
            ),
          ),
        );
      },
    );
  }

  // ─── 任务列表 ───────────────────────────────────────────────

  /// 当前"班级|章节"标识, 作为错题数据的归属 key
  String _wrongQuestionKeyOf(WeekendState st) =>
      '${st.selectedClassId ?? ''}|${st.currentChapterId ?? ''}';

  /// 加载周练错题解析 (章节 wrongQuestionTask/detail)
  ///
  /// 切换班级/教材/章节后 key 变化 → 先清空旧数据再拉取, 并在响应回来时
  /// 校验 key 是否仍匹配, 丢弃过期响应, 避免展示上一个章节的 paperId。
  Future<void> _loadWrongQuestions({bool force = false}) async {
    final st = ref.read(weekendProvider);
    final chapterId = st.currentChapterId ?? '';
    final classId = st.selectedClassId ?? '';
    final key = _wrongQuestionKeyOf(st);

    // 同一章节且已加载过则跳过 (force=true 由刷新按钮触发)
    if (!force && _wrongQuestionKey == key) return;

    // 立即占位 + 清空旧数据: 防止重复触发, 也避免脏 paperId 残留
    _wrongQuestionKey = key;
    if (!mounted) return;
    setState(() {
      _wrongQuestionDetail = {};
      _wrongQuestionError = null;
      _wrongQuestionPlaying = null;
      _wrongQuestionLoading = true;
    });

    if (chapterId.isEmpty || classId.isEmpty) {
      setState(() {
        _wrongQuestionLoading = false;
        _wrongQuestionError = '缺少章节/班级信息';
      });
      return;
    }

    try {
      final remote = WeekendRemoteDataSource(getIt<DioClient>());
      final detail = await remote.getWrongQuestionDetail(
        chapterId: chapterId,
        classId: classId,
      );
      // 请求期间已切换章节/班级 → 丢弃过期响应
      if (!mounted || _wrongQuestionKey != key) return;
      setState(() {
        _wrongQuestionDetail = detail;
        _wrongQuestionLoading = false;
      });
    } catch (e) {
      if (!mounted || _wrongQuestionKey != key) return;
      setState(() {
        _wrongQuestionLoading = false;
        _wrongQuestionError = '$e';
      });
    }
  }

  /// 播放周练错题视频 (VideoPlayLauncher)
  Future<void> _playWrongQuestion(Map<String, dynamic> item) async {
    final lessonId = (item['lessonId'] ?? '').toString();
    if (lessonId.isEmpty) return;
    setState(() => _wrongQuestionPlaying = lessonId);
    try {
      final authState = ref.read(authProvider);
      final session =
          authState is AuthAuthenticated ? authState.session : null;
      final remote = PlayerRemoteDataSource(getIt<DioClient>());
      Map<String, dynamic> videoInfo = {};
      try {
        final schoolId = session?.schoolId ?? '';
        final token = await remote.getPlayerToken(
          schoolId: schoolId,
          lessonId: lessonId,
        );
        if (token.isNotEmpty) {
          videoInfo = await remote.getExternalVideoInfo(
            lessonId: lessonId,
            videoToken: token,
          );
        }
      } catch (_) {}
      if (!mounted) return;
      if (videoInfo.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未获取到该错题的视频源, 无法播放')),
        );
        return;
      }
      await VideoPlayLauncher.start(
        context: context,
        videoInfo: videoInfo,
        lessonId: lessonId,
        homeworkId: '', // 周培优无 homeworkId
        videoId: '',
        taskId: '',
        contentType: 1, // 错题视频为视频类型
        duration: 0,
        title: (item['lessonName'] ?? '错题视频').toString(),
        userSession: session,
      );
    } finally {
      if (mounted) setState(() => _wrongQuestionPlaying = null);
    }
  }

  /// 周练错题解析卡片 (任务列表顶部, 默认收起, 可展开/收起)
  ///
  /// 数据随当前"班级|章节"自动刷新: key 不一致时下一帧触发重新拉取,
  /// 且在同步完成前不展示旧的 paperId / 错题列表。
  Widget _buildWrongQuestionSection(WeekendState state, ThemeData theme) {
    final key = _wrongQuestionKeyOf(state);
    final synced = _wrongQuestionKey == key;

    if (!synced) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _wrongQuestionKey != key) _loadWrongQuestions();
      });
    }

    final detail = synced ? _wrongQuestionDetail : const <String, dynamic>{};
    final paperId = (detail['paperId'] ?? '').toString();
    final rawList = (detail['list'] as List<dynamic>?) ?? const <dynamic>[];
    final loading = !synced || _wrongQuestionLoading;
    final error = synced ? _wrongQuestionError : null;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题行 (可点击展开/收起)
          InkWell(
            onTap: () => setState(() => _wrongQuestionExpanded = !_wrongQuestionExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
              child: Row(
                children: [
                  Icon(Icons.quiz_outlined,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    '周练错题解析',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (paperId.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        '试卷ID: $paperId',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (rawList.isNotEmpty)
                    Text(
                      '${rawList.length} 题',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: '刷新错题列表',
                    visualDensity: VisualDensity.compact,
                    onPressed: loading
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            await _loadWrongQuestions(force: true);
                            if (!mounted) return;
                            showAppSnackBar(
                              messenger,
                              _wrongQuestionError == null
                                  ? '刷新完成'
                                  : '刷新失败: $_wrongQuestionError',
                              isError: _wrongQuestionError != null,
                            );
                          },
                  ),
                  // 展开/收起按钮
                  Icon(
                    _wrongQuestionExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 22,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          // 错题列表 (展开时显示; 超出高度时内部滚动, 避免溢出)
          if (_wrongQuestionExpanded) ...[
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: _buildWrongQuestionList(theme, rawList, loading, error),
            ),
          ],
        ],
      ),
    );
  }

  /// 错题列表主体 (错误 / 空 / 列表 三态)
  Widget _buildWrongQuestionList(
    ThemeData theme,
    List<dynamic> rawList,
    bool loading,
    String? error,
  ) {
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.error_outline,
                size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: () => _loadWrongQuestions(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (rawList.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Text(
          loading ? '加载中...' : '暂无错题',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: rawList.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final item = rawList[index];
        if (item is! Map<String, dynamic>) return const SizedBox.shrink();

        final lessonId = (item['lessonId'] ?? '').toString();
        final lessonName = (item['lessonName'] ?? '错题').toString();
        final isComplete = item['lessonIsComplete'] == true ||
            item['lessonIsComplete'] == 1;
        final playing = _wrongQuestionPlaying == lessonId;

        return Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Icon(
              isComplete ? Icons.check_circle_outline : Icons.error_outline,
              size: 18,
              color: isComplete
                  ? const Color(0xFF2ECC71)
                  : const Color(0xFFE74C3C),
            ),
            title: Text(
              lessonName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            trailing: playing
                ? const SizedBox(
                    width: 32,
                    height: 32,
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.play_arrow),
                    tooltip: '播放视频',
                    // 已有其它错题在解析视频源时禁用, 避免并发弹窗互相顶掉
                    onPressed: _wrongQuestionPlaying != null
                        ? null
                        : () => _playWrongQuestion(item),
                  ),
          ),
        );
      },
    );
  }

  /// 提取任务标题 (兼容多种字段名)
  String _taskTitleOf(Map<String, dynamic> task) =>
      task['taskTitle']?.toString() ??
      task['taskName']?.toString() ??
      task['name']?.toString() ??
      task['title']?.toString() ??
      '';

  Widget _buildTaskList(WeekendState state, ThemeData theme, bool isWide) {
    if (state.tasks.isEmpty) {
      return _buildEmptyView(
        icon: Icons.task_alt_outlined,
        title: '暂无任务',
        subtitle: '该章节下没有学习任务',
        theme: theme,
      );
    }

    // 网格列数按宽度档位递增: 窄屏单列, 中屏双列, 大屏三列。
    final crossAxisCount = switch (context.windowSize) {
      WindowSize.compact => 1,
      WindowSize.medium => 2,
      _ => 3,
    };

    // 拆分任务: "周练错题解析" 单独渲染为顶部常驻卡片 (高度自适应 + 内部滚动),
    // 其余任务进网格。gridIndices 保留原始下标, 保证多选状态不错位。
    final gridIndices = <int>[];
    var hasWrongQuestionTask = false;
    for (var i = 0; i < state.tasks.length; i++) {
      final raw = state.tasks[i];
      final title = raw is Map<String, dynamic> ? _taskTitleOf(raw) : '';
      if (title.contains('错题解析')) {
        hasWrongQuestionTask = true;
      } else {
        gridIndices.add(i);
      }
    }

    return Column(
      children: [
        if (hasWrongQuestionTask) _buildWrongQuestionSection(state, theme),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: isWide ? 3.8 : 3.2,
            ),
            itemCount: gridIndices.length,
            itemBuilder: (context, gridIndex) {
              final index = gridIndices[gridIndex];
              final task = state.tasks[index] as Map<String, dynamic>;
              final taskTitle = _taskTitleOf(task);

              return ContextMenuRegion(
                title: taskTitle.length > 20
                    ? '${taskTitle.substring(0, 20)}...'
                    : taskTitle,
                menuBuilder: (_) => _selectable
                    ? _multiSelectMenuItems()
                    : [
                        ContextMenuItem(
                          id: 'detail',
                          label: '查看详情',
                          icon: Icons.info_outline,
                          enabled: RiskControlGate.isFeatureEnabled('weekend_menu.view_detail'),
                          onTap: () => _openTaskDetail(task),
                        ),
                        const ContextMenuItem.divider(),
                        ..._actionMenuItems(
                          onAction: (action) => _executeAction(task, action),
                        ),
                        const ContextMenuItem.divider(),
                        ContextMenuItem(
                          id: 'multi_select',
                          label: '多选',
                          icon: Icons.checklist_outlined,
                          enabled: RiskControlGate.isFeatureEnabled('weekend_menu.multi_select'),
                          onTap: () {
                            setState(() {
                              _selectable = true;
                              _selectedIndices.add(index);
                            });
                          },
                        ),
                      ],
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _selectable
                      ? () {
                          setState(() {
                            if (_selectedIndices.contains(index)) {
                              _selectedIndices.remove(index);
                            } else {
                              _selectedIndices.add(index);
                            }
                          });
                        }
                      : () => _openTaskDetail(task),
                  child: _TaskCard(
                    task: task,
                    selectable: _selectable,
                    selected: _selectedIndices.contains(index),
                    onToggleSelect: _selectable
                        ? () {
                            setState(() {
                              if (_selectedIndices.contains(index)) {
                                _selectedIndices.remove(index);
                              } else {
                                _selectedIndices.add(index);
                              }
                            });
                          }
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ─── 空状态 ─────────────────────────────────────────────────

  Widget _buildEmptyView({
    required IconData icon,
    required String title,
    required String subtitle,
    required ThemeData theme,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 章节卡片
// ═══════════════════════════════════════════════════════════════

class _ChapterCard extends StatelessWidget {
  final Map<String, dynamic> chapter;
  final bool selectable;
  final bool selected;
  final VoidCallback? onToggleSelect;

  const _ChapterCard({
    required this.chapter,
    this.selectable = false,
    this.selected = false,
    this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = chapter['chapterName']?.toString() ??
        chapter['name']?.toString() ??
        '未知章节';
    final isRecent = chapter['isRecent'] == true || chapter['isRecent'] == 1;
    final isOpen = chapter['status'] == true || chapter['status'] == 1;
    final canLearn = chapter['canLearnFlag'] == true ||
        chapter['canLearnFlag'] == 1 ||
        isOpen;

    final (statusLabel, statusColor) = _parseStatus(isRecent, isOpen, canLearn);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // 多选 checkbox
            if (selectable) ...[
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: selected,
                  onChanged: (_) => onToggleSelect?.call(),
                ),
              ),
              const SizedBox(width: 10),
            ],
            // 左侧色条
            Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: canLearn
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 14),
            // 章节名称
            Expanded(
              child: Text(
                name,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: canLearn
                      ? null
                      : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // 状态徽章
            if (statusLabel.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: statusColor,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Icon(
              canLearn ? Icons.chevron_right : Icons.lock_outline,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }

  (String, Color) _parseStatus(bool isRecent, bool isOpen, bool canLearn) {
    if (isRecent) {
      return ('最近', const Color(0xFFE74C3C));
    } else if (isOpen) {
      return ('已开课', const Color(0xFF2ECC71));
    } else {
      return ('未开课', const Color(0xFF95A5A6));
    }
  }
}

// ═══════════════════════════════════════════════════════════════
// 任务卡片
// ═══════════════════════════════════════════════════════════════

class _TaskCard extends StatelessWidget {
  final Map<String, dynamic> task;
  final bool selectable;
  final bool selected;
  final VoidCallback? onToggleSelect;

  const _TaskCard({
    required this.task,
    this.selectable = false,
    this.selected = false,
    this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final title = task['taskTitle']?.toString() ??
        task['taskName']?.toString() ??
        task['name']?.toString() ??
        task['title']?.toString() ??
        '未知任务';
    final subject = task['subject']?.toString() ??
        task['subjectName']?.toString() ??
        '';
    final taskType = task['contentTypeName']?.toString() ??
        task['taskType']?.toString() ??
        task['typeName']?.toString() ??
        '';
    final className = task['className']?.toString() ?? '';
    final duration = task['duration']?.toString() ?? '';
    final progress = task['taskProgress']?.toString() ??
        task['progress']?.toString() ??
        '';
    final isComplete = task['lessonIsComplete'] == true ||
        task['lessonIsComplete'] == 1 ||
        task['paperIsComplete'] == true ||
        task['paperIsComplete'] == 1;
    final status = isComplete
        ? '已完成'
        : (task['status']?.toString() ?? task['statusName']?.toString() ?? '');

    final subjectColor = _colorForSubject(subject);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      child: InkWell(
        onTap: selectable ? onToggleSelect : null,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // 多选 checkbox
              if (selectable) ...[
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: selected,
                    onChanged: (_) => onToggleSelect?.call(),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              // 学科色条
              Container(
                width: 4,
                height: 52,
                decoration: BoxDecoration(
                  color: subjectColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 14),
              // 内容区
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 标题行
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (taskType.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: subjectColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              taskType,
                              style: TextStyle(
                                fontSize: 11,
                                color: subjectColor,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Meta 行: 班级 · 时长 · 进度
                    Text(
                      [
                        if (className.isNotEmpty) className,
                        if (duration.isNotEmpty) duration,
                        if (progress.isNotEmpty) '进度 $progress',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 状态指示
              if (status.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _taskStatusColor(status).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: _taskStatusColor(status),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Color _taskStatusColor(String status) {
    if (status.contains('已完成') || status.contains('完成')) {
      return const Color(0xFF2ECC71);
    } else if (status.contains('进行中') || status.contains('学习中')) {
      return const Color(0xFF3498DB);
    } else if (status.contains('未开始') || status.contains('未学习')) {
      return const Color(0xFF95A5A6);
    }
    return const Color(0xFF607D8B);
  }
}
