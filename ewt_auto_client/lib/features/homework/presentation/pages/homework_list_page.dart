/// 作业/任务列表页，含作业列表与课程两种视图、滚动分页加载、课程多选及右键批量操作（进度上报/答案/下载/提交）。
/// 任务级操作作用于该作业下所有日期的所有课程。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/config/endpoint_config.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/layout/app_breakpoints.dart';
import '../../../../core/network/dio_client.dart';
import '../../../../core/risk_control/risk_control_gate.dart';
import '../../../../core/widgets/context_menu_region.dart';
import '../../../../shared/utils/app_feedback.dart';
import '../../../answer/domain/entities/answer_config.dart';
import '../../../answer/presentation/pages/answer_config_page.dart';
import '../../../answer/presentation/pages/answer_pdf_preview_page.dart';
import '../../../answer/presentation/pages/answer_result_page.dart';
import '../../../answer/presentation/services/answer_export_helper.dart';
import '../../../answer/presentation/services/answer_service.dart';
import '../../../answer/presentation/services/answer_submit_helper.dart';
import '../../../answer/presentation/services/submit_paper_helper.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../download/presentation/services/download_service.dart';
import '../../../download/presentation/dialogs/download_config_dialog.dart';
import '../../../player/domain/services/video_source_resolver.dart';
import '../../../player/presentation/pages/report_config_page.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../../player/presentation/services/progress_report_service.dart';
import '../dialogs/course_detail_dialog.dart';
import '../providers/homework_provider.dart';
import '../../../../core/constants/subject_constants.dart';

/// 作业/任务列表页
///
/// 对应 Python: gui/interfaces/my_tasks.py
class HomeworkListPage extends ConsumerStatefulWidget {
  const HomeworkListPage({super.key});

  @override
  ConsumerState<HomeworkListPage> createState() => _HomeworkListPageState();
}

class _HomeworkListPageState extends ConsumerState<HomeworkListPage> {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _dateScrollController = ScrollController();

  /// 课程视图多选模式
  bool _courseSelectable = false;
  Set<int> _selectedCourseIndices = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(homeworkProvider.notifier).loadTasks(refresh: true);
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _dateScrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(homeworkProvider.notifier).loadMore();
    }
  }

  // ─── 任务操作 ───

  /// 任务卡片右键菜单: 拉取该作业下所有日期的所有课程 → 执行批量操作
  ///
  /// 对应 Python: 任务级操作作用于该作业下所有课程
  Future<void> _executeTaskAction(
      Map<String, dynamic> task, String action) async {
    final homeworkId =
        task['homeworkId']?.toString() ?? task['id']?.toString() ?? '';
    final title = task['title']?.toString() ?? '任务';

    if (homeworkId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('[$title] 缺少 homeworkId'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // 拉取该作业下所有日期的课程
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('[$title] 正在加载课程列表...'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );

    final courses =
        await ref.read(homeworkProvider.notifier).fetchAllCourses(homeworkId);
    if (courses.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('[$title] 未找到课程'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // 临时切换 currentHomeworkId 以便下游 _startProgressReport 等方法读到
    // (不切换 viewMode, 不影响 UI)
    // 通过 enterCourseView 完成切换会清空课程列表, 不合适;
    // 这里直接调用 _executeActionWithCourses, 并在调用前设置 currentHomeworkId
    // 但 currentHomeworkId 由 provider 管理, 这里通过 selectDate 后再调用会改变 state;
    // 最稳妥的方式: 不依赖 provider 的 currentHomeworkId, 而是直接构造下游调用所需参数。
    if (!mounted) return;
    await _executeActionWithCourses(
      courses,
      action,
      homeworkId: homeworkId,
      progressTitle: title,
    );
  }

  void _executeCourseAction(Map<String, dynamic> course, String action) {
    if (action == 'report') {
      _startProgressReport([course]);
      return;
    }
    if (action == 'answers') {
      _startAnswerFetch([course]);
      return;
    }
    if (action == 'submit_paper') {
      _executeSubmitPaper([course]);
      return;
    }
    if (action.startsWith('download_')) {
      _startDownload([course], action);
      return;
    }
    final title = course['title']?.toString() ?? '课程';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('[$title] ${_actionLabel(action)} - 功能开发中'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 通用: 用给定课程列表执行对应操作 (供任务卡片/日期 chip 批量操作复用)
  ///
  /// 由于 _startProgressReport / _startAnswerFetch / _startDownload 内部
  /// 都从 ref.read(homeworkProvider).currentHomeworkId 取 homeworkId,
  /// 此处需在调用前通过 [homeworkId] 临时切换 provider 状态 (仅 currentHomeworkId 字段)。
  Future<void> _executeActionWithCourses(
    List<Map<String, dynamic>> courses,
    String action, {
    required String homeworkId,
    required String progressTitle,
  }) async {
    // 临时设置 currentHomeworkId (不切换 viewMode)
    // 通过 Notifier 暴露的 setCurrentHomeworkId 完成
    ref.read(homeworkProvider.notifier).setCurrentHomeworkId(homeworkId);

    try {
      if (action == 'report') {
        await _startProgressReport(courses);
      } else if (action == 'answers') {
        await _startAnswerFetch(courses);
      } else if (action == 'submit_paper') {
        await _executeSubmitPaper(courses);
      } else if (action.startsWith('download_')) {
        await _startDownload(courses, action);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_actionLabel(action)} - 未知操作'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      // 任务列表视图下 (非课程视图) 不还原, 避免影响下游异步流程;
      // currentHomeworkId 在 loadTasks 时会被重置
    }
  }

  void _openCourseDetail(Map<String, dynamic> course) {
    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    final schoolId = session?.schoolId ?? '';
    final homeworkId =
        ref.read(homeworkProvider).currentHomeworkId ?? '';

    showDialog(
      context: context,
      builder: (_) => CourseDetailDialog(
        courseData: course,
        homeworkId: homeworkId,
        schoolId: schoolId,
        userSession: session,
      ),
    );
  }

  void _batchCourseAction(String action) {
    final state = ref.read(homeworkProvider);
    // 使用学科筛选后的列表 (与 UI 展示一致)
    final visibleCourses = state.filteredCourses;
    final selectedCourses = _selectedCourseIndices
        .where((i) => i < visibleCourses.length)
        .map((i) => visibleCourses[i])
        .toList();
    if (selectedCourses.isNotEmpty) {
      if (action == 'report') {
        _startProgressReport(selectedCourses);
      } else if (action == 'answers') {
        _startAnswerFetch(selectedCourses);
      } else if (action == 'submit_paper') {
        _executeSubmitPaper(selectedCourses);
      } else if (action.startsWith('download_')) {
        _startDownload(selectedCourses, action);
      }
    }
    _exitMultiSelect();
  }

  /// 启动进度上报流程: 配置页 → 过滤 → 执行
  Future<void> _startProgressReport(
      List<Map<String, dynamic>> courses) async {
    final homeworkId =
        ref.read(homeworkProvider).currentHomeworkId ?? '';

    // 动态加载学科列表 (优先动态, 失败回退本地列表)
    List<String>? dynamicSubjects;
    if (homeworkId.isNotEmpty) {
      final fetched =
          await ref.read(homeworkProvider.notifier).fetchSubjectList(homeworkId);
      if (fetched.isNotEmpty) dynamicSubjects = fetched;
    }

    // 1. 打开配置页
    if (!mounted) return;
    final config = await ReportConfigPage.show(context, subjects: dynamicSubjects);
    if (config == null || !mounted) return;

    // 2. 创建服务并过滤课程
    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    final service = ProgressReportService(
      client: getIt<DioClient>(),
      endpointConfig: getIt<EndpointConfig>(),
      userSession: session,
    );

    final schoolId = session?.schoolId ?? '';
    final tasks = service.filterCourses(
      courses,
      config,
      homeworkId,
      schoolId: schoolId,
    );

    if (tasks.isEmpty) {
      service.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('没有符合条件的课程需要上报'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // 3. 构建进度项
    final items = tasks
        .map((t) => TaskProgressItem(title: t.title, subtitle: t.lessonId))
        .toList();

    // 4. 显示进度弹窗
    if (!mounted) return;
    TaskProgressDialog.show(
      context,
      items: items,
      logStream: service.logStream,
      title: '进度上报',
      progressPoller: config.realProgressQuery
          ? () => service.queryRealProgress(tasks)
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

    // 5. 执行批量上报
    await service.executeBatch(
      tasks,
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

  /// 启动试题答案获取流程
  Future<void> _startAnswerFetch(
      List<Map<String, dynamic>> courses) async {
    final homeworkId =
        ref.read(homeworkProvider).currentHomeworkId ?? '';

    // 动态加载学科列表 (优先动态, 失败回退本地列表)
    List<String>? dynamicSubjects;
    if (homeworkId.isNotEmpty) {
      final fetched =
          await ref.read(homeworkProvider.notifier).fetchSubjectList(homeworkId);
      if (fetched.isNotEmpty) dynamicSubjects = fetched;
    }

    // 打开合并配置页 (方案 + 展示字段 + 过滤选项, 一次完成)
    if (!mounted) return;
    final result = await AnswerConfigPage.show(context, subjects: dynamicSubjects);
    if (result == null || !mounted) return;
    final config = result.config;
    final filterConfig = result.filterConfig;

    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    final schoolId = session?.schoolId ?? '';

    // 预过滤课程列表 (对应 Python _apply_answer_filter)
    final filteredCourses =
        AnswerService.applyFilter(courses, filterConfig);
    if (filteredCourses.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('过滤后没有符合条件的课程')),
        );
      }
      return;
    }

    // ─── 下载方案: 不获取答案题目, 改由服务端生成教师版试卷 PDF, 在预览页打开 ───
    if (config.method == AnswerMethod.download) {
      final service = DownloadService(client: getIt<DioClient>());
      final dialogKey = GlobalKey<TaskProgressDialogState>();

      final items = filteredCourses
          .map((c) => TaskProgressItem(
                title: (c['title'] ?? c['taskTitle'] ?? '课程').toString(),
                subtitle: (c['lessonId'] ?? c['contentId'] ?? '').toString(),
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
        filteredCourses,
        homeworkId: homeworkId,
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
    final items = filteredCourses
        .map((c) => TaskProgressItem(
              title: (c['title'] ?? c['taskTitle'] ?? '课程').toString(),
              subtitle: (c['lessonId'] ?? c['contentId'] ?? '').toString(),
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

    // 执行批量获取
    final results = await service.executeBatch(
      filteredCourses,
      homeworkId: homeworkId,
      schoolId: schoolId,
      method: config.method.value,
      filterConfig: filterConfig,
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

    // 获取完成操作: 获取完成后按配置自动提交 (无操作则跳过)
    final submitType = config.submitType;
    if (submitType != null && results.isNotEmpty && mounted) {
      await AnswerSubmitHelper.submitResults(
        client: getIt<DioClient>(),
        results: results,
        type: submitType,
        questionTypes: config.submitQuestionTypes,
        imageUploadConfig: config.imageUploadConfig,
        dialogContext: context,
      );
    }

    // 获取完成操作: 按配置自动导出 (每课程单独 / 全部合并单文件)
    final exportMode = config.exportMode;
    if (exportMode != null && results.isNotEmpty && mounted) {
      await AnswerExportHelper.exportResults(
        results: results,
        mode: exportMode,
      );
    }

    // 不关闭弹窗: 标记完成, 直接进入答案页, 方便返回查看日志
    if (!dialogDismissed) {
      dialogKey.currentState?.markFinished();
      if (mounted && results.isNotEmpty) {
        AnswerResultPage.push(context, results: results, displayConfig: config);
      }
    }
  }

  /// 启动"提交试卷": 获取试卷 → 手动填写答案/上传图片 → 提交作答结果
  Future<void> _executeSubmitPaper(
      List<Map<String, dynamic>> courses) async {
    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    final schoolId = session?.schoolId ?? '';
    final homeworkId =
        ref.read(homeworkProvider).currentHomeworkId ?? '';
    if (courses.isEmpty) return;
    await SubmitPaperHelper.run(
      context,
      courses,
      homeworkId: homeworkId,
      schoolId: schoolId,
    );
  }

  /// 启动下载流程 (导学案/视频/试题)
  Future<void> _startDownload(
      List<Map<String, dynamic>> courses, String action) async {
    final authState = ref.read(authProvider);
    final session =
        authState is AuthAuthenticated ? authState.session : null;
    final homeworkId =
        ref.read(homeworkProvider).currentHomeworkId ?? '';
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

    final items = courses
        .map((c) => TaskProgressItem(
              title: (c['title'] ?? c['taskTitle'] ?? '课程').toString(),
              subtitle: (c['lessonId'] ?? c['contentId'] ?? '').toString(),
            ))
        .toList();

    if (!mounted) return;
    TaskProgressDialog.show(
      context,
      items: items,
      logStream: service.logStream,
      title: _downloadDialogTitle(action),
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
        await service.downloadGuides(courses,
            homeworkId: homeworkId, schoolId: schoolId,
            onItemUpdate: onItemUpdate);
      case 'download_video':
        await service.downloadVideos(courses,
            homeworkId: homeworkId, schoolId: schoolId,
            line: videoLine,
            onItemUpdate: onItemUpdate);
      case 'download_paper':
        await service.downloadPapers(courses,
            homeworkId: homeworkId, schoolId: schoolId,
            onItemUpdate: onItemUpdate);
      default:
        break;
    }

    service.dispose();

    // 标记完成: 弹窗按钮从"停止"变为"关闭", 用户可查看日志后手动关闭
    dialogKey.currentState?.markFinished();
  }

  /// 日期 chip 右键菜单批量操作: 拉取该日期下所有课程 → 执行批量操作
  ///
  /// 对应 Python: 日期级操作作用于该日期下所有课程
  Future<void> _batchDateAction(
      Map<String, dynamic> day, String action) async {
    final label = _dateLabel(day, 0);
    final homeworkId = ref.read(homeworkProvider).currentHomeworkId ?? '';
    final dateId = day['dateId']?.toString() ??
        day['dayId']?.toString() ??
        day['id']?.toString() ??
        '';

    if (homeworkId.isEmpty || dateId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('[$label] 缺少 homeworkId 或 dateId'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('[$label] 正在加载课程列表...'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );

    final courses = await ref
        .read(homeworkProvider.notifier)
        .fetchCoursesForDate(homeworkId, dateId);
    if (courses.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('[$label] 未找到课程'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    await _executeActionWithCourses(
      courses,
      action,
      homeworkId: homeworkId,
      progressTitle: label,
    );
  }

  /// 学科 chip 右键/长按批量操作: 拉取该作业所有日期课程 → 按学科过滤 → 执行批量操作
  ///
  /// 对应 Python: 学科级操作作用于该学科下所有日期所有课程
  Future<void> _batchSubjectAction(
      Map<String, dynamic> subject, String action) async {
    final subjectName = subject['subjectName']?.toString() ?? '学科';
    final homeworkId = ref.read(homeworkProvider).currentHomeworkId ?? '';
    final subjectId = subject['subjectId'];

    if (homeworkId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('[$subjectName] 缺少 homeworkId'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('[$subjectName] 正在加载课程列表...'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );

    // 拉取该作业下所有日期课程, 客户端按 subjectId 过滤
    final allCourses =
        await ref.read(homeworkProvider.notifier).fetchAllCourses(homeworkId);
    final courses = allCourses.where((c) {
      final sid = c['subjectId'];
      if (sid == null || subjectId == null) return false;
      return sid is int
          ? sid == subjectId
          : int.tryParse(sid.toString()) == subjectId;
    }).toList();

    if (courses.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('[$subjectName] 未找到课程'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (!mounted) return;
    await _executeActionWithCourses(
      courses,
      action,
      homeworkId: homeworkId,
      progressTitle: subjectName,
    );
  }

  String _actionLabel(String action) {
    return switch (action) {
      'report' => '进度上报',
      'answers' => '试题答案',
      'submit_paper' => '提交试卷',
      'download_paper' => '下载试题',
      'download_video' => '下载视频',
      'download_guide' => '下载导学案',
      'download_merged_guide' => '下载合并导学案',
      _ => action,
    };
  }

  /// 下载/答案弹窗的标题
  String _downloadDialogTitle(String action) {
    return switch (action) {
      'download_paper' => '下载试题',
      'download_video' => '下载视频',
      'download_guide' => '下载导学案',
      'download_merged_guide' => '下载合并导学案',
      _ => _actionLabel(action),
    };
  }

  /// 通用操作菜单项
  List<ContextMenuItem> _actionMenuItems({
    required void Function(String action) onAction,
    bool includeMergedGuide = false,
  }) {
    return [
      ContextMenuItem(
        id: 'report',
        label: '进度上报',
        icon: Icons.upload_outlined,
        enabled: RiskControlGate.isFeatureEnabled('homework_menu.report'),
        onTap: () => onAction('report'),
      ),
      ContextMenuItem(
        id: 'answers',
        label: '试题答案',
        icon: Icons.quiz_outlined,
        enabled: RiskControlGate.isFeatureEnabled('homework_menu.answers'),
        onTap: () => onAction('answers'),
      ),
      ContextMenuItem(
        id: 'submit_paper',
        label: '提交试卷',
        icon: Icons.task_alt_outlined,
        enabled: RiskControlGate.isFeatureEnabled('homework_menu.submit_paper'),
        onTap: () => onAction('submit_paper'),
      ),
      const ContextMenuItem.divider(),
      ContextMenuItem(
        id: 'download_paper',
        label: '下载试题',
        icon: Icons.description_outlined,
        enabled: RiskControlGate.isFeatureEnabled('homework_menu.download_paper'),
        onTap: () => onAction('download_paper'),
      ),
      ContextMenuItem(
        id: 'download_video',
        label: '下载视频',
        icon: Icons.video_file_outlined,
        enabled: RiskControlGate.isFeatureEnabled('homework_menu.download_video'),
        onTap: () => onAction('download_video'),
      ),
      ContextMenuItem(
        id: 'download_guide',
        label: '下载导学案',
        icon: Icons.menu_book_outlined,
        enabled: RiskControlGate.isFeatureEnabled('homework_menu.download_guide'),
        onTap: () => onAction('download_guide'),
      ),
      if (includeMergedGuide)
        ContextMenuItem(
          id: 'download_merged_guide',
          label: '下载合并导学案',
          icon: Icons.merge_type_outlined,
          enabled: RiskControlGate.isFeatureEnabled(
              'homework_menu.download_merged_guide'),
          onTap: () => onAction('download_merged_guide'),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeworkProvider);
    final theme = Theme.of(context);
    final isWide = context.isWide;

    if (state.viewMode == 'courses') {
      return _buildCourseView(context, ref, state, theme, isWide);
    }

    return _buildTaskListView(context, ref, state, theme, isWide);
  }

  // ─── Task List View ───

  Widget _buildTaskListView(
    BuildContext context,
    WidgetRef ref,
    HomeworkState state,
    ThemeData theme,
    bool isWide,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('我的任务'),
            if (state.totalCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${state.totalCount}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: state.isLoading
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await ref
                        .read(homeworkProvider.notifier)
                        .loadTasks(refresh: true);
                    if (!context.mounted) return;
                    final st = ref.read(homeworkProvider);
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
          _buildFilterRow(context, ref, state, theme),
          const Divider(height: 1),
          Expanded(
            child: _buildTaskListContent(context, state, theme, isWide),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow(
    BuildContext context,
    WidgetRef ref,
    HomeworkState state,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: _FilterDropdown(
              label: '状态',
              options: statusFilterOptions,
              selected: state.filterStatus,
              onChanged: (value) {
                ref.read(homeworkProvider.notifier).setFilter(
                      status: () => value,
                    );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _FilterDropdown(
              label: '学科',
              options: subjectFilterOptions,
              selected: state.filterSubject,
              onChanged: (value) {
                ref.read(homeworkProvider.notifier).setFilter(
                      subject: () => value,
                    );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _FilterDropdown(
              label: '类型',
              options: typeFilterOptions,
              selected: state.filterType,
              onChanged: (value) {
                ref.read(homeworkProvider.notifier).setFilter(
                      type: () => value,
                    );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskListContent(
    BuildContext context,
    HomeworkState state,
    ThemeData theme,
    bool isWide,
  ) {
    if (state.error != null && state.tasks.isEmpty) {
      return _ErrorState(
        message: state.error!,
        onRetry: () =>
            ref.read(homeworkProvider.notifier).loadTasks(refresh: true),
      );
    }

    if (state.isLoading && state.tasks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.tasks.isEmpty) {
      return _EmptyState(
        icon: Icons.assignment_outlined,
        title: '暂无任务数据',
        subtitle: '当前筛选条件下没有作业任务',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 网格列数按宽度档位递增: 窄屏单列, 宽屏双列, 大屏三列。
        final crossAxisCount = switch (context.windowSize) {
          WindowSize.compact => 1,
          WindowSize.medium => 2,
          _ => 3,
        };
        return GridView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            mainAxisExtent: 180,
          ),
          itemCount: state.tasks.length + (state.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= state.tasks.length) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final task = state.tasks[index];
            final taskTitle = task['title']?.toString() ?? '';
            return ContextMenuRegion(
              title: taskTitle.length > 20
                  ? '${taskTitle.substring(0, 20)}...'
                  : taskTitle,
              menuBuilder: (_) => _actionMenuItems(
                includeMergedGuide: true,
                onAction: (action) => _executeTaskAction(task, action),
              ),
              child: _TaskCard(
                task: task,
                onTap: () {
                  final homeworkId = task['homeworkId']?.toString() ??
                      task['id']?.toString();
                  if (homeworkId != null) {
                    ref
                        .read(homeworkProvider.notifier)
                        .enterCourseView(homeworkId, title: taskTitle);
                  }
                },
              ),
            );
          },
        );
      },
    );
  }

  // ─── Course View ───

  Widget _buildCourseView(
    BuildContext context,
    WidgetRef ref,
    HomeworkState state,
    ThemeData theme,
    bool isWide,
  ) {
    return Scaffold(
      appBar: AppBar(
        leading: _courseSelectable
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitMultiSelect,
              )
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    ref.read(homeworkProvider.notifier).backToTasks(),
              ),
        title: _courseSelectable
            ? Text('已选 ${_selectedCourseIndices.length} 项')
            : Text(
                state.currentHomeworkTitle ?? '课程任务',
                overflow: TextOverflow.ellipsis,
              ),
        actions: _courseSelectable
            ? [
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  tooltip: '运行',
                  onPressed: _selectedCourseIndices.isNotEmpty
                      ? _showBatchActionDialog
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: '全选',
                  onPressed: _selectAllCourses,
                ),
                IconButton(
                  icon: const Icon(Icons.flip),
                  tooltip: '反选',
                  onPressed: _invertSelection,
                ),
              ]
            : null,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.dateStats.isNotEmpty || state.subjectStats.isNotEmpty)
            _buildFilterHeader(state, theme),
          const Divider(height: 1),
          Expanded(
            child: _buildCourseListContent(state, theme, isWide),
          ),
        ],
      ),
    );
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
          '批量执行 (${_selectedCourseIndices.length} 项)',
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
                  _batchCourseAction(action);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _exitMultiSelect() {
    setState(() {
      _courseSelectable = false;
      _selectedCourseIndices.clear();
    });
  }

  void _selectAllCourses() {
    final state = ref.read(homeworkProvider);
    final courses = state.filteredCourses;
    setState(() {
      if (_selectedCourseIndices.length == courses.length) {
        _selectedCourseIndices.clear();
      } else {
        _selectedCourseIndices.addAll(
          List.generate(courses.length, (i) => i),
        );
      }
    });
  }

  void _invertSelection() {
    final state = ref.read(homeworkProvider);
    final courses = state.filteredCourses;
    setState(() {
      final all = List.generate(courses.length, (i) => i).toSet();
      _selectedCourseIndices = all.difference(_selectedCourseIndices);
    });
  }

  void _toggleCourseSelection(int index) {
    setState(() {
      if (_selectedCourseIndices.contains(index)) {
        _selectedCourseIndices.remove(index);
      } else {
        _selectedCourseIndices.add(index);
      }
    });
  }

  // ─── Filter Header (日期/学科切换, 二者互斥) ───

  /// 筛选头部: 展开按钮 + 模式切换(日期|学科) + 对应 chips
  ///
  /// 日期模式: 显示日期 chips, 按日期筛选课程
  /// 学科模式: 显示学科 chips, 显示该学科所有日期课程
  Widget _buildFilterHeader(HomeworkState state, ThemeData theme) {
    final header = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          // 展开按钮 (日期模式: 选择日期; 学科模式: 选择学科)
          if (state.filterMode == 'date' && state.dateStats.isNotEmpty)
            PopupMenuButton<int>(
              tooltip: '选择日期',
              icon: const Icon(Icons.unfold_more, size: 20),
              offset: const Offset(0, 40),
              onSelected: (index) {
                if (index == -1) {
                  _showMultiDateDialog();
                  return;
                }
                final day = state.dateStats[index];
                final dayId = day['dateId']?.toString() ??
                    day['dayId']?.toString() ?? '';
                ref.read(homeworkProvider.notifier).selectDate(dayId);
                _scrollToDate(index);
              },
              itemBuilder: (context) => [
                const PopupMenuItem<int>(
                  value: -1,
                  child: Row(
                    children: [
                      Icon(Icons.checklist, size: 18),
                      SizedBox(width: 10),
                      Text('多选日期...'),
                    ],
                  ),
                ),
                const PopupMenuDivider(height: 8),
                for (int i = 0; i < state.dateStats.length; i++)
                  PopupMenuItem<int>(
                    value: i,
                    child: Text(
                      '${_dateLabel(state.dateStats[i], i)}  '
                      '${state.dateStats[i]['finishCount'] ?? 0}/${state.dateStats[i]['taskCount'] ?? 0}',
                    ),
                  ),
              ],
            )
          else if (state.filterMode == 'subject' &&
              state.subjectStats.isNotEmpty)
            PopupMenuButton<int>(
              tooltip: '选择学科',
              icon: const Icon(Icons.unfold_more, size: 20),
              offset: const Offset(0, 40),
              onSelected: (index) {
                if (index == -1) {
                  _showMultiSubjectDialog();
                  return;
                }
                if (index == 0) {
                  ref.read(homeworkProvider.notifier).selectSubject(null);
                } else {
                  final sid = state.subjectStats[index - 1]['subjectId'];
                  ref
                      .read(homeworkProvider.notifier)
                      .selectSubject(sid is int ? sid : int.tryParse(sid.toString()));
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem<int>(
                  value: -1,
                  child: Row(
                    children: [
                      Icon(Icons.checklist, size: 18),
                      SizedBox(width: 10),
                      Text('多选学科...'),
                    ],
                  ),
                ),
                const PopupMenuDivider(height: 8),
                const PopupMenuItem<int>(
                  value: 0,
                  child: Text('全部学科'),
                ),
                for (int i = 0; i < state.subjectStats.length; i++)
                  PopupMenuItem<int>(
                    value: i + 1,
                    child: Text(
                      '${state.subjectStats[i]['subjectName']}  '
                      '${state.subjectStats[i]['finishCount'] ?? 0}/${state.subjectStats[i]['taskCount'] ?? 0}',
                    ),
                  ),
              ],
            ),
          // 模式切换按钮 (日期 | 学科)
          _buildModeToggle(state, theme),
          const SizedBox(width: 4),
          // chips (根据模式显示)
          Expanded(
            child: state.filterMode == 'date'
                ? _buildDateChipsRow(state, theme)
                : _buildSubjectChipsRow(state, theme),
          ),
        ],
      ),
    );

    return header;
  }

  /// 弹出学科多选弹窗 (支持全选/反选/清除/确认)
  Future<void> _showMultiSubjectDialog() async {
    final state = ref.read(homeworkProvider);
    if (state.subjectStats.isEmpty) return;
    final result = await showDialog<Set<int>>(
      context: context,
      builder: (_) => _SubjectMultiSelectDialog(
        subjectStats: state.subjectStats,
        initialSelected: state.selectedSubjectIds,
      ),
    );
    if (result != null) {
      ref
          .read(homeworkProvider.notifier)
          .applyMultiSubjectSelection(result.toList());
    }
  }

  /// 弹出日期多选弹窗 (支持全选/反选/清除/确认)
  Future<void> _showMultiDateDialog() async {
    final state = ref.read(homeworkProvider);
    if (state.dateStats.isEmpty) return;
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _DateMultiSelectDialog(
        dateStats: state.dateStats,
        initialSelected: state.selectedDateIds,
      ),
    );
    if (result != null) {
      await ref.read(homeworkProvider.notifier).applyMultiDateSelection(
            result.toList(),
          );
    }
  }

  /// 模式切换: 日期 / 学科 (互斥)
  ///
  /// 宽度充足时使用 SegmentedButton (图标+文字);
  /// 窄屏 (移动端, <600dp) 时单个 IconButton, 图标随当前模式切换,
  /// 点击切换到另一模式, 不带选中高亮。
  Widget _buildModeToggle(HomeworkState state, ThemeData theme) {
    final isNarrow = context.isNarrow;

    if (isNarrow) {
      final isDate = state.filterMode == 'date';
      return IconButton(
        tooltip: isDate ? '切换到学科' : '切换到日期',
        icon: Icon(
          isDate ? Icons.calendar_today : Icons.menu_book,
          size: 20,
        ),
        onPressed: () {
          if (_courseSelectable) _exitMultiSelect();
          ref
              .read(homeworkProvider.notifier)
              .setFilterMode(isDate ? 'subject' : 'date');
        },
      );
    }

    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(
          value: 'date',
          label: Text('日期'),
          icon: Icon(Icons.calendar_today, size: 14),
        ),
        ButtonSegment(
          value: 'subject',
          label: Text('学科'),
          icon: Icon(Icons.menu_book, size: 14),
        ),
      ],
      selected: {state.filterMode},
      onSelectionChanged: (selection) {
        final mode = selection.first;
        if (_courseSelectable) _exitMultiSelect();
        ref.read(homeworkProvider.notifier).setFilterMode(mode);
      },
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        ),
        textStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  /// 日期 chips 行 (日期模式)
  Widget _buildDateChipsRow(HomeworkState state, ThemeData theme) {
    return SingleChildScrollView(
      controller: _dateScrollController,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // 多选模式指示 + 退出
          if (state.dateMultiSelect)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InputChip(
                label: Text('多选 ${state.selectedDateIds.length} 个'),
                avatar: const Icon(Icons.checklist, size: 16),
                selected: true,
                visualDensity: VisualDensity.compact,
                onSelected: (_) =>
                    ref.read(homeworkProvider.notifier).exitDateMultiSelect(),
                onDeleted: () =>
                    ref.read(homeworkProvider.notifier).exitDateMultiSelect(),
                deleteIcon: const Icon(Icons.close, size: 16),
              ),
            ),
          for (int index = 0; index < state.dateStats.length; index++) ...[
            if (index > 0) const SizedBox(width: 8),
            Builder(builder: (context) {
              final day = state.dateStats[index];
              final dayId = day['dateId']?.toString() ??
                  day['dayId']?.toString() ?? '';
              final taskCount = day['taskCount']?.toString() ?? '0';
              final finishCount = day['finishCount']?.toString() ?? '0';
              final isSelected = state.dateMultiSelect
                  ? state.selectedDateIds.contains(dayId)
                  : state.selectedDateId == dayId;

              return ContextMenuRegion(
                title: '${_dateLabel(day, index)} ($taskCount 个课程)',
                menuBuilder: (_) => [
                  ContextMenuItem(
                    id: 'view',
                    label: '查看课程 ($taskCount)',
                    icon: Icons.visibility_outlined,
                    enabled: taskCount != '0',
                    onTap: () {
                      ref.read(homeworkProvider.notifier).selectDate(dayId);
                      _scrollToDate(index);
                    },
                  ),
                  const ContextMenuItem.divider(),
                  ..._actionMenuItems(
                    onAction: (action) => _batchDateAction(day, action),
                  ),
                ],
                child: ChoiceChip(
                  label: Text(
                      '${_dateLabel(day, index)} $finishCount/$taskCount'),
                  selected: isSelected,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) {
                    ref.read(homeworkProvider.notifier).selectDate(dayId);
                    _scrollToDate(index);
                  },
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  /// 学科 chips 行 (学科模式)
  Widget _buildSubjectChipsRow(HomeworkState state, ThemeData theme) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // 多选模式指示 + 退出
          if (state.subjectMultiSelect)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InputChip(
                label: Text('多选 ${state.selectedSubjectIds.length} 科'),
                avatar: const Icon(Icons.checklist, size: 16),
                selected: true,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => ref
                    .read(homeworkProvider.notifier)
                    .exitSubjectMultiSelect(),
                onDeleted: () => ref
                    .read(homeworkProvider.notifier)
                    .exitSubjectMultiSelect(),
                deleteIcon: const Icon(Icons.close, size: 16),
              ),
            ),
          for (int index = 0; index < state.subjectStats.length; index++) ...[
            if (index > 0) const SizedBox(width: 6),
            Builder(builder: (context) {
              final subject = state.subjectStats[index];
              final subjectId = subject['subjectId'] as int?;
              final subjectName =
                  subject['subjectName']?.toString() ?? '未知';
              final taskCount = subject['taskCount']?.toString() ?? '0';
              final finishCount = subject['finishCount']?.toString() ?? '0';
              final isSelected = state.subjectMultiSelect
                  ? state.selectedSubjectIds.contains(subjectId)
                  : state.selectedSubjectId == subjectId;

              return ContextMenuRegion(
                title: '$subjectName ($taskCount 个课程)',
                menuBuilder: (_) => [
                  ContextMenuItem(
                    id: 'view',
                    label: '查看课程 ($taskCount)',
                    icon: Icons.visibility_outlined,
                    enabled: taskCount != '0',
                    onTap: () {
                      if (_courseSelectable) _exitMultiSelect();
                      ref
                          .read(homeworkProvider.notifier)
                          .selectSubject(subjectId);
                    },
                  ),
                  const ContextMenuItem.divider(),
                  ..._actionMenuItems(
                    onAction: (action) =>
                        _batchSubjectAction(subject, action),
                  ),
                ],
                child: ChoiceChip(
                  label: Text('$subjectName $finishCount/$taskCount'),
                  selected: isSelected,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) {
                    if (_courseSelectable) _exitMultiSelect();
                    ref
                        .read(homeworkProvider.notifier)
                        .selectSubject(subjectId);
                  },
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  String _dateLabel(Map<String, dynamic> day, int index) {
    final month = day['month']?.toString() ?? '';
    final dayNum = day['day']?.toString() ?? '';
    return (month.isNotEmpty && dayNum.isNotEmpty)
        ? '$month月$dayNum日'
        : '第${index + 1}天';
  }

  void _scrollToDate(int index) {
    final targetOffset = (index * 110.0) - 40;
    final maxScroll = _dateScrollController.position.maxScrollExtent;
    final clamped = targetOffset.clamp(0.0, maxScroll);
    _dateScrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  // ─── Course List ───

  Widget _buildCourseListContent(
    HomeworkState state,
    ThemeData theme,
    bool isWide,
  ) {
    if (state.isCourseLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null && state.courses.isEmpty) {
      return _ErrorState(
        message: state.error!,
        onRetry: () {
          final dateId = state.selectedDateId;
          if (dateId != null) {
            ref.read(homeworkProvider.notifier).selectDate(dateId);
          }
        },
      );
    }

    if (state.courses.isEmpty) {
      return const _EmptyState(
        icon: Icons.event_available_outlined,
        title: '暂无课程',
        subtitle: '该日期下没有布置任务',
      );
    }

    // 应用学科筛选 (客户端过滤, 日期筛选已在加载时应用)
    final courses = state.filteredCourses;

    if (courses.isEmpty) {
      return _EmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: '暂无课程',
        subtitle: '当前学科筛选下没有课程',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: courses.length,
      itemBuilder: (context, index) {
        final course = courses[index];
        final courseTitle = course['title']?.toString() ?? '';

        return ContextMenuRegion(
          title: courseTitle.length > 20
              ? '${courseTitle.substring(0, 20)}...'
              : courseTitle,
          menuBuilder: (_) => _courseSelectable
              ? _multiSelectMenuItems()
              : [
                  ContextMenuItem(
                    id: 'detail',
                    label: '查看详情',
                    icon: Icons.info_outline,
                    onTap: () => _openCourseDetail(course),
                  ),
                  const ContextMenuItem.divider(),
                  ..._actionMenuItems(
                    onAction: (action) =>
                        _executeCourseAction(course, action),
                  ),
                  const ContextMenuItem.divider(),
                  ContextMenuItem(
                    id: 'multi_select',
                    label: '多选',
                    icon: Icons.checklist_outlined,
                    onTap: () {
                      setState(() {
                        _courseSelectable = true;
                        _selectedCourseIndices.add(index);
                      });
                    },
                  ),
                ],
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _courseSelectable
                ? () => _toggleCourseSelection(index)
                : () => _openCourseDetail(course),
            child: _CourseCard(
              course: course,
              isWide: isWide,
              selectable: _courseSelectable,
              selected: _selectedCourseIndices.contains(index),
              onToggleSelect: _courseSelectable
                  ? () => _toggleCourseSelection(index)
                  : null,
            ),
          ),
        );
      },
    );
  }

  List<ContextMenuItem> _multiSelectMenuItems() {
    final hasSelection = _selectedCourseIndices.isNotEmpty;
    return [
      ContextMenuItem(
        id: 'exit_multi',
        label: '退出多选',
        icon: Icons.close_outlined,
        onTap: _exitMultiSelect,
      ),
      ContextMenuItem(
        id: 'select_all',
        label: '全选 / 取消全选',
        icon: Icons.select_all_outlined,
        onTap: _selectAllCourses,
      ),
      ContextMenuItem(
        id: 'invert',
        label: '反选',
        icon: Icons.flip_outlined,
        onTap: _invertSelection,
      ),
      const ContextMenuItem.divider(),
      ContextMenuItem(
        id: 'report',
        label: '进度上报',
        icon: Icons.upload_outlined,
        enabled: hasSelection,
        onTap: () => _batchCourseAction('report'),
      ),
      ContextMenuItem(
        id: 'answers',
        label: '试题答案',
        icon: Icons.quiz_outlined,
        enabled: hasSelection,
        onTap: () => _batchCourseAction('answers'),
      ),
      ContextMenuItem(
        id: 'submit_paper',
        label: '提交试卷',
        icon: Icons.task_alt_outlined,
        enabled: hasSelection,
        onTap: () => _batchCourseAction('submit_paper'),
      ),
      const ContextMenuItem.divider(),
      ContextMenuItem(
        id: 'download_paper',
        label: '下载试题',
        icon: Icons.description_outlined,
        enabled: hasSelection,
        onTap: () => _batchCourseAction('download_paper'),
      ),
      ContextMenuItem(
        id: 'download_video',
        label: '下载视频',
        icon: Icons.video_file_outlined,
        enabled: hasSelection,
        onTap: () => _batchCourseAction('download_video'),
      ),
      ContextMenuItem(
        id: 'download_guide',
        label: '下载导学案',
        icon: Icons.menu_book_outlined,
        enabled: hasSelection,
        onTap: () => _batchCourseAction('download_guide'),
      ),
    ];
  }
}

// ─── Widgets ───

/// 筛选下拉按钮
class _FilterDropdown extends StatelessWidget {
  final String label;
  final List<(int?, String)> options;
  final int? selected;
  final ValueChanged<int?> onChanged;

  const _FilterDropdown({
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedLabel = options.firstWhere(
      (o) => o.$1 == selected,
      orElse: () => options.first,
    ).$2;

    // 用索引作为 PopupMenuButton 的值，避免 null 值不触发 onSelected
    final selectedIndex = options.indexWhere((o) => o.$1 == selected);

    return PopupMenuButton<int>(
      tooltip: '筛选$label',
      offset: const Offset(0, 40),
      onSelected: (index) => onChanged(options[index].$1),
      itemBuilder: (context) => [
        for (int i = 0; i < options.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                if (i == selectedIndex)
                  Icon(Icons.check, size: 18, color: theme.colorScheme.primary)
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                Text(options[i].$2),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$label: $selectedLabel',
                style: theme.textTheme.labelMedium,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 任务卡片
class _TaskCard extends StatelessWidget {
  final Map<String, dynamic> task;
  final VoidCallback? onTap;

  const _TaskCard({required this.task, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final title = task['title']?.toString() ??
        task['homeworkTitle']?.toString() ??
        '未命名作业';
    final sceneTypeName = task['sceneTypeName']?.toString() ?? '';
    final teacherName = task['teacherName']?.toString() ?? '';
    final isPlan = task['isPlan'] == true;
    final startTime = _formatTimestamp(task['startTime'] ?? task['startDate']);
    final endTime = _formatTimestamp(task['endTime'] ?? task['endDate']);

    final types = (task['types'] as List<dynamic>?)
            ?.map((e) => (e as Map<String, dynamic>)['text']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList() ??
        [];

    final subjects = (task['subjects'] as List<dynamic>?)
            ?.map((e) => (e as Map<String, dynamic>)['text']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList() ??
        [];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (sceneTypeName.isNotEmpty)
                    _tag(theme, sceneTypeName,
                        theme.colorScheme.primaryContainer,
                        theme.colorScheme.onPrimaryContainer),
                  if (isPlan)
                    _tag(theme, '计划',
                        theme.colorScheme.secondaryContainer,
                        theme.colorScheme.onSecondaryContainer),
                  for (final t in types)
                    _tag(theme, t,
                        theme.colorScheme.surfaceContainerHighest,
                        theme.colorScheme.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 8),
              if (subjects.isNotEmpty)
                Text(
                  subjects.join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              const Spacer(),
              Text(
                [
                  if (teacherName.isNotEmpty) teacherName,
                  if (startTime != null) '开始: $startTime',
                  if (endTime != null) '截止: $endTime',
                ].join('  '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tag(ThemeData theme, String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 课程卡片（课程视图中的单个任务）
class _CourseCard extends StatelessWidget {
  final Map<String, dynamic> course;
  final bool isWide;
  final bool selectable;
  final bool selected;
  final VoidCallback? onToggleSelect;

  const _CourseCard({
    required this.course,
    required this.isWide,
    this.selectable = false,
    this.selected = false,
    this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final subjectId = _parseInt(course['subjectId']);
    final subjectColor = subjectColorMap[subjectId] ?? const Color(0xFF546E7A);
    final subjectName =
        course['subjectName']?.toString() ?? subjectNameMap[subjectId] ?? '未知';
    final title = course['title']?.toString() ?? '未命名任务';
    final contentTypeName = course['contentTypeName']?.toString() ?? '';
    final duration = _parseInt(course['duration']);
    final durationMin = duration > 0 ? '${(duration / 60).ceil()}分钟' : '';

    // 内容类型判断: 试卷不显示观看状态和进度
    final isPaper = contentTypeName.contains('试卷') ||
        contentTypeName.contains('作业') ||
        contentTypeName.contains('考试');
    final isVideo = contentTypeName.contains('视频') ||
        contentTypeName.contains('课程') ||
        contentTypeName.isEmpty;

    // 观看进度 (仅视频类内容)
    final ratio = (course['ratio'] is num)
        ? (course['ratio'] as num).toDouble()
        : 0.0;
    final clientPlayTime = _parseInt(course['clientPlayTime']);
    final videoProgress = (!isPaper && ratio > 0)
        ? ratio
        : (!isPaper && duration > 0 && clientPlayTime > 0)
            ? (clientPlayTime / 1000 / duration).clamp(0.0, 1.0)
            : 0.0;
    final videoWatched = !isPaper && videoProgress >= 0.95;
    final showVideoStatus = !isPaper && (videoProgress > 0 || isVideo);

    // 作业状态: 统一使用 queryStudentLessonStudyGuideAndPractice 的 finishStatus
    // (studyTest/practiceSheet 任一 finishStatus==1 才视为作业完成)
    // taskId 非空即视为有作业 (控制是否展示作业状态标签)
    final taskId = course['taskId']?.toString() ?? '';
    final hasHomework = taskId.isNotEmpty && taskId != '0';
    final homeworkDone = _parseInt(course['homeworkFinishStatus']) == 1;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
      child: InkWell(
        onTap: selectable ? onToggleSelect : null,
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
                const SizedBox(width: 12),
              ],
              // Subject icon
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: subjectColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    subjectName.isNotEmpty ? subjectName[0] : '?',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: subjectColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [subjectName, contentTypeName, durationMin]
                          .where((s) => s.isNotEmpty)
                          .join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    // 观看进度条 (仅视频类且有进度时)
                    if (showVideoStatus && videoProgress > 0 && !videoWatched) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: videoProgress.clamp(0.0, 1.0),
                          minHeight: 3,
                          backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // 状态指示区
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 视频状态 (试卷不显示)
                  if (showVideoStatus)
                    _StatusChip(
                      icon: videoWatched
                          ? Icons.play_circle_filled
                          : Icons.play_circle_outline,
                      label: videoWatched ? '已观看' : '未观看',
                      color: videoWatched
                          ? Colors.green
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  // 作业状态
                  if (hasHomework) ...[
                    if (showVideoStatus) const SizedBox(height: 4),
                    _StatusChip(
                      icon: homeworkDone
                          ? Icons.assignment_turned_in
                          : Icons.assignment_outlined,
                      label: homeworkDone ? '已完成' : '未完成',
                      color: homeworkDone
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                  // 进度百分比
                  if (showVideoStatus && videoProgress > 0 && videoProgress < 0.95) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${(videoProgress * 100).toInt()}%',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态小标签（图标+文字）
class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatusChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: color),
        ),
      ],
    );
  }
}

/// 空状态
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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

/// 错误状态
class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _ErrorState({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Helpers ───

int _parseInt(dynamic value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  if (value is double) return value.toInt();
  return 0;
}

String? _formatTimestamp(dynamic value) {
  final ms = _parseInt(value);
  if (ms <= 0) return null;
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${dt.year}年${dt.month}月${dt.day}日';
}

// ─── 日期多选弹窗 ───

class _DateItem {
  final String id;
  final String label;
  final int taskCount;
  final int finishCount;
  const _DateItem({
    required this.id,
    required this.label,
    required this.taskCount,
    required this.finishCount,
  });
}

/// 日期多选弹窗
///
/// 列出当前作业下所有日期, 支持勾选多个日期; 提供 全选 / 反选 / 清除 高级操作,
/// 确认后返回选中的日期 ID 集合 (`Set<String>`)。
class _DateMultiSelectDialog extends StatefulWidget {
  final List<Map<String, dynamic>> dateStats;
  final Set<String> initialSelected;

  const _DateMultiSelectDialog({
    required this.dateStats,
    required this.initialSelected,
  });

  @override
  State<_DateMultiSelectDialog> createState() => _DateMultiSelectDialogState();
}

class _DateMultiSelectDialogState extends State<_DateMultiSelectDialog> {
  late Set<String> _selected;
  late final List<_DateItem> _items;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initialSelected};
    _items = [
      for (var i = 0; i < widget.dateStats.length; i++)
        _DateItem(
          id: widget.dateStats[i]['dateId']?.toString() ??
              widget.dateStats[i]['dayId']?.toString() ??
              widget.dateStats[i]['id']?.toString() ??
              '',
          label: _dateLabel(widget.dateStats[i], i),
          taskCount: _parseInt(widget.dateStats[i]['taskCount']),
          finishCount: _parseInt(widget.dateStats[i]['finishCount']),
        ),
    ];
  }

  static String _dateLabel(Map<String, dynamic> day, int index) {
    final month = day['month']?.toString() ?? '';
    final dayNum = day['day']?.toString() ?? '';
    return (month.isNotEmpty && dayNum.isNotEmpty)
        ? '$month月$dayNum日'
        : '第${index + 1}天';
  }

  void _selectAll() =>
      setState(() => _selected = _items.map((e) => e.id).toSet());
  void _invert() => setState(() {
        final all = _items.map((e) => e.id).toSet();
        _selected = all.difference(_selected);
      });
  void _clear() => setState(() => _selected.clear());

  @override
  Widget build(BuildContext context) {
    // 高度自适应屏幕: 桌面 380, 小屏/横屏取 70% 屏高 (最低 280), 防止溢出
    final contentHeight = (MediaQuery.sizeOf(context).height * 0.7).clamp(280.0, 380.0);
    return AlertDialog(
      title: Text('多选日期 (${_selected.length}/${_items.length})'),
      // 固定宽度 + 固定高度 (禁止 width:double.infinity+ListView, 会触发 M3
      // IntrinsicWidth 固有宽度查询穿透到 viewport 导致布局异常/程序卡死)
      content: SizedBox(
        width: 360,
        height: contentHeight,
        child: ListView.builder(
          itemCount: _items.length,
          itemBuilder: (context, i) {
            final it = _items[i];
            return CheckboxListTile(
              title: Text(it.label),
              subtitle: Text('${it.finishCount}/${it.taskCount} 已完成'),
              value: _selected.contains(it.id),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(it.id);
                } else {
                  _selected.remove(it.id);
                }
              }),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: _selectAll, child: const Text('全选')),
        TextButton(onPressed: _invert, child: const Text('反选')),
        TextButton(onPressed: _clear, child: const Text('清除')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确认'),
        ),
      ],
    );
  }
}

// ─── 学科多选弹窗 ───

class _SubjectItem {
  final int id;
  final String label;
  final int taskCount;
  final int finishCount;
  const _SubjectItem({
    required this.id,
    required this.label,
    required this.taskCount,
    required this.finishCount,
  });
}

/// 学科多选弹窗
///
/// 列出当前作业下所有学科, 支持勾选多个学科; 提供 全选 / 反选 / 清除 高级操作,
/// 确认后返回选中的学科 ID 集合 (`Set<int>`)。
class _SubjectMultiSelectDialog extends StatefulWidget {
  final List<Map<String, dynamic>> subjectStats;
  final Set<int> initialSelected;

  const _SubjectMultiSelectDialog({
    required this.subjectStats,
    required this.initialSelected,
  });

  @override
  State<_SubjectMultiSelectDialog> createState() =>
      _SubjectMultiSelectDialogState();
}

class _SubjectMultiSelectDialogState extends State<_SubjectMultiSelectDialog> {
  late Set<int> _selected;
  late final List<_SubjectItem> _items;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initialSelected};
    _items = [
      for (final s in widget.subjectStats)
        _SubjectItem(
          id: s['subjectId'] is int
              ? s['subjectId'] as int
              : int.tryParse(s['subjectId']?.toString() ?? '') ?? -1,
          label: s['subjectName']?.toString() ?? '未知',
          taskCount: _parseInt(s['taskCount']),
          finishCount: _parseInt(s['finishCount']),
        ),
    ];
  }

  void _selectAll() =>
      setState(() => _selected = _items.map((e) => e.id).toSet());
  void _invert() => setState(() {
        final all = _items.map((e) => e.id).toSet();
        _selected = all.difference(_selected);
      });
  void _clear() => setState(() => _selected.clear());

  @override
  Widget build(BuildContext context) {
    // 高度自适应屏幕: 桌面 380, 小屏/横屏取 70% 屏高 (最低 280), 防止溢出
    final contentHeight = (MediaQuery.sizeOf(context).height * 0.7).clamp(280.0, 380.0);
    return AlertDialog(
      title: Text('多选学科 (${_selected.length}/${_items.length})'),
      // 固定宽度 + 固定高度 (禁止 width:double.infinity+ListView, 会触发 M3
      // IntrinsicWidth 固有宽度查询穿透到 viewport 导致布局异常/程序卡死)
      content: SizedBox(
        width: 360,
        height: contentHeight,
        child: ListView.builder(
          itemCount: _items.length,
          itemBuilder: (context, i) {
            final it = _items[i];
            return CheckboxListTile(
              title: Text(it.label),
              subtitle: Text('${it.finishCount}/${it.taskCount} 已完成'),
              value: _selected.contains(it.id),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(it.id);
                } else {
                  _selected.remove(it.id);
                }
              }),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: _selectAll, child: const Text('全选')),
        TextButton(onPressed: _invert, child: const Text('反选')),
        TextButton(onPressed: _clear, child: const Text('清除')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确认'),
        ),
      ],
    );
  }
}
