/// 答案展示页面，TabBar 切换多课程，支持按展示字段配置渲染与导出 PDF（默认沿用抓取时的展示配置）。
/// 必须经 GoRouter 的 context.push('/answer-result') 打开，避免页面被推入 ShellRoute 内层导航导致状态冲突。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/network/dio_client.dart';
import '../../../player/domain/entities/video_session.dart';
import '../../../player/presentation/dialogs/task_progress_dialog.dart';
import '../../data/datasources/answer_remote_datasource.dart';
import '../../data/services/oss_upload_service.dart';
import '../../domain/entities/export_font_config.dart';
import '../../domain/entities/image_upload_config.dart';
import '../../domain/entities/question_info.dart';
import '../../domain/services/answer_submit_service.dart';
import '../../domain/services/paper_pdf_exporter.dart';
import '../../domain/entities/answer_config.dart';
import '../dialogs/submit_config_dialog.dart';
import '../services/manual_submit_helper.dart';
import '../widgets/ewt_html_render.dart'
    show
        buildEwtHtmlExtensions,
        ewtHtmlStyle;

/// 答案展示页面 (替代原 AnswerResultDialog)
///
/// 对应 Python: gui/dialogs/answer.py AnswerDisplayDialog
/// 使用页面 + TabBar 切换多课程, 顶部右上角导出按钮。
class AnswerResultPage extends StatefulWidget {
  final List<CourseAnswerResult> results;

  /// 展示字段配置 (控制原题/选项/答案/知识点/难度/解析是否展示)
  final AnswerConfig displayConfig;

  const AnswerResultPage({
    super.key,
    required this.results,
    this.displayConfig = const AnswerConfig(),
  });

  /// 跳转到答案展示页
  ///
  /// 使用 GoRouter 的 root navigator (context.push) 而非 Navigator.of(context).push,
  /// 避免页面被推到 ShellRoute 的内层 navigator 上, 导致:
  /// - 覆盖底部导航栏 (点击"首页"等无法切换)
  /// - 返回时与 ShellRoute 状态冲突, 出现红色错误屏
  static Future<void> push(
    BuildContext context, {
    required List<CourseAnswerResult> results,
    AnswerConfig displayConfig = const AnswerConfig(),
  }) {
    return context.push(
      '/answer-result',
      extra: {
        'results': results,
        'displayConfig': displayConfig,
      },
    );
  }

  @override
  State<AnswerResultPage> createState() => _AnswerResultPageState();
}

class _AnswerResultPageState extends State<AnswerResultPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _tabController =
        TabController(length: widget.results.length, vsync: this);
    // 导出字段默认沿用"获取试题答案"时的展示配置 (displayConfig),
    // 保证"所见即所得": 屏幕上被隐藏的字段, 导出 PDF 默认也不包含.
    // 用户仍可在"导出配置..."中单独调整/覆盖.
    _exportFields = _fieldsFromDisplayConfig(widget.displayConfig);
  }

  /// 将抓取阶段的 AnswerConfig 展示字段映射为导出字段配置
  ///
  /// AnswerConfig 含 原题目/选项/答案/知识点/难度/解析 六项;
  /// AnswerExportFields 额外有 showQuestionType (题型, 抓取配置无对应项, 默认 true).
  static AnswerExportFields _fieldsFromDisplayConfig(AnswerConfig c) =>
      AnswerExportFields(
        showQuestionContent: c.showQuestionContent,
        showOptions: c.showOptions,
        showAnswer: c.showAnswer,
        showKnowledge: c.showKnowledge,
        showDifficulty: c.showDifficulty,
        showAnalysis: c.showAnalysis,
      );

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalQuestions =
        widget.results.fold<int>(0, (sum, r) => sum + r.successCount);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.results.length == 1
              ? widget.results.first.courseTitle
              : '试题答案 (${widget.results.length} 课程, $totalQuestions 题)',
        ),
        actions: [
          // 复制当前课程
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: '复制当前课程答案',
            onPressed: _copyCurrent,
          ),
          // 提交按钮 (上传图标, 菜单: 提交做题痕迹/提交答题结果/批量提交)
          PopupMenuButton<String>(
            icon: const Icon(Icons.upload_outlined),
            tooltip: '提交',
            onSelected: _onSubmitSelected,
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'trace', child: Text('提交做题痕迹')),
              const PopupMenuItem(
                  value: 'result', child: Text('提交答题结果')),
              // 手动提交: 打开手动填写页, 支持边看已获取答案边填写 (不限获取方案)
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'manual', child: Text('手动提交')),
              if (widget.results.length > 1)
                const PopupMenuItem(
                    value: 'manual_all', child: Text('手动提交全部课程')),
              if (widget.results.length > 1) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(
                    value: 'all_trace',
                    child: Text('提交全部课程做题痕迹')),
                const PopupMenuItem(
                    value: 'all_result',
                    child: Text('提交全部课程作答结果')),
              ],
            ],
          ),
          // 导出按钮 (右上角)
          PopupMenuButton<String>(
            icon: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_outlined),
            tooltip: '导出 PDF',
            onSelected: _onExportSelected,
            enabled: !_exporting,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'current', child: Text('导出当前课程')),
              PopupMenuItem(
                  value: 'all', child: Text('全部课程合并单文件导出')),
              PopupMenuItem(
                  value: 'single_each', child: Text('每课程单独导出')),
              PopupMenuItem(value: 'config', child: Text('导出配置...')),
            ],
          ),
        ],
        bottom: widget.results.length > 1
            ? TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: widget.results
                    .map((r) => Tab(
                          text: _tabLabel(r),
                        ))
                    .toList(),
              )
            : null,
      ),
      body: widget.results.isEmpty
          ? const Center(child: Text('未获取到答案'))
          : widget.results.length == 1
              ? _CourseAnswerView(
                  result: widget.results.first,
                  config: widget.displayConfig,
                )
              : TabBarView(
                  controller: _tabController,
                  children: widget.results
                      .map((r) => _CourseAnswerView(
                            result: r,
                            config: widget.displayConfig,
                          ))
                      .toList(),
                ),
    );
  }

  String _tabLabel(CourseAnswerResult r) {
    // Tab 标签: 优先用学科+标题, 过长截断
    final title = r.courseTitle;
    if (title.length > 12) return '${title.substring(0, 12)}…';
    return title;
  }

  Future<void> _copyCurrent() async {
    final index = _tabController.index;
    if (index >= widget.results.length) return;
    final result = widget.results[index];
    final buffer = StringBuffer();
    buffer.writeln('═══ ${result.courseTitle} ═══');
    buffer.writeln(
        '方案: ${result.method} | paperId: ${result.paperId} | ${result.successCount}/${result.totalCount} 题');
    buffer.writeln();
    for (final q in result.questions) {
      _writeQuestion(buffer, q, indent: '');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('答案已复制到剪贴板'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _writeQuestion(StringBuffer buffer, QuestionInfo q,
      {required String indent}) {
    final num = q.number.isNotEmpty ? '${q.number}. ' : '';
    buffer.writeln('$indent$num答案: ${_stripHtml(q.answer)}');
    if (q.knowledge.isNotEmpty) {
      buffer.writeln('$indent   知识点: ${q.knowledge}');
    }
    if (q.analysis.isNotEmpty) {
      buffer.writeln('$indent   解析: ${_stripHtml(q.analysis)}');
    }
    for (final child in q.childQuestions) {
      _writeQuestion(buffer, child, indent: '$indent   ');
    }
  }

  String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<img[^>]*>'), '[图片]')
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>'), '\n')
        .replaceAll(RegExp(r'</div>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .trim();
  }

  /// 提交菜单回调
  ///
  /// - trace: 提交当前课程做题痕迹 (仅保存答案, 不交卷)
  /// - result: 提交当前课程答题结果 (保存答案 + 最终交卷)
  /// - manual: 手动提交当前课程 (打开手动填写页, 支持边看答案边填写)
  /// - manual_all: 手动提交全部课程 (TAB 切换填写, 支持边看答案边填写)
  /// - all_trace: 批量提交全部课程做题痕迹
  /// - all_result: 批量提交全部课程作答结果
  ///
  /// 单课程与批量均通过 [TaskProgressDialog] 实时展示日志与进度。
  Future<void> _onSubmitSelected(String value) async {
    switch (value) {
      case 'trace':
        await _submitSingle(SubmitType.trace);
      case 'result':
        await _submitSingle(SubmitType.result);
      case 'manual':
        await _submitManual(allCourses: false);
      case 'manual_all':
        await _submitManual(allCourses: true);
      case 'all_trace':
        await _submitBatch(SubmitType.trace);
      case 'all_result':
        await _submitBatch(SubmitType.result);
    }
  }

  /// 手动提交: 选择提交类型后打开手动填写页 (双栏"查看答案"预览),
  /// 经 [ManualSubmitOrchestrator] 批量提交, 任意获取方案均可边看答案边填写。
  Future<void> _submitManual({required bool allCourses}) async {
    final type = await _pickSubmitType();
    if (type == null || !mounted) return;
    final results = allCourses
        ? widget.results
        : [widget.results[_tabController.index]];
    final r = await ManualSubmitOrchestrator.run(
      context: context,
      results: results,
      type: type,
      showAnswerPreview: true,
    );
    if (!mounted || r.cancelled) return;
    final typeLabel = type == SubmitType.trace ? '做题痕迹' : '答题结果';
    final allOk = r.fail == 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(allOk
            ? '全部 ${r.ok} 个课程提交$typeLabel成功'
            : '完成: 成功 ${r.ok}, 失败 ${r.fail}'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: allOk ? 3 : 6),
        backgroundColor:
            allOk ? Colors.green.shade700 : Colors.orange.shade700,
      ),
    );
  }

  /// 选择提交类型 (手动提交用): 做题痕迹 / 答题结果
  Future<SubmitType?> _pickSubmitType() {
    return showDialog<SubmitType>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动提交'),
        content: const Text('请选择提交类型'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, SubmitType.trace),
            child: const Text('做题痕迹'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, SubmitType.result),
            child: const Text('答题结果'),
          ),
        ],
      ),
    );
  }

  /// 构造提交服务 (含 OSS 上传通道, 供主观题图片上传)
  ///
  /// 注入 [context] 给 [AnswerSubmitService.renderContext],
  /// 让"根据答案/解析生成图片"方案能通过 [Overlay] + [flutter_html]
  /// 渲染 HTML 与图片/公式 (与答案展示页一致)。
  AnswerSubmitService _buildSubmitService() {
    final dioClient = getIt<DioClient>();
    final remote = AnswerRemoteDataSource(dioClient);
    final ossUploader = OssUploadService(dioClient);
    return AnswerSubmitService(
      remote,
      ossUploader: ossUploader,
      renderContext: context,
    );
  }

  /// 提交单课程答案, 带"提交配置弹窗"+"进度/日志弹窗"
  ///
  /// 流程:
  /// 1. [SubmitConfigDialog] 选择题型与图片上传方案, 确认后关闭;
  /// 2. [TaskProgressDialog] 实时展示提交日志与进度 (与提交任务并行);
  /// 3. 完成后标记弹窗为"已完成" (按钮由"停止"变"关闭"), 用户可查看日志后手动关闭。
  Future<void> _submitSingle(SubmitType type) async {
    final index = _tabController.index;
    if (index >= widget.results.length) return;
    final result = widget.results[index];
    final service = _buildSubmitService();

    final typeLabel = type == SubmitType.trace ? '做题痕迹' : '答题结果';

    // 1. 提交配置弹窗 (选题型 + 图片上传方案)
    //    onConfirm 仅捕获配置并关闭弹窗, 实际提交在进度弹窗中执行,
    //    以便实时展示日志与进度。
    List<QuestionInfo> selectedQuestions = result.questions;
    ImageUploadConfig? imageUploadConfig = _imageUploadConfig;
    String? manualReportId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => SubmitConfigDialog(
        result: result,
        type: type,
        initialImageUploadConfig: _imageUploadConfig,
        onConfirm: (qs, cfg, reportId) async {
          selectedQuestions = qs;
          if (cfg != null) {
            _imageUploadConfig = cfg;
            imageUploadConfig = cfg;
          }
          manualReportId = reportId;
          Navigator.of(context).pop(true);
        },
      ),
    );
    if (confirmed != true || !mounted) {
      service.dispose();
      return;
    }
    // 手动填写/修改的 reportId 覆盖原值后提交
    final effectiveResult = (manualReportId != null &&
            manualReportId != result.reportId)
        ? result.copyWith(reportId: manualReportId)
        : result;

    // 2. 进度/日志弹窗 (fire-and-forget, 与提交任务并行)
    final dialogKey = GlobalKey<TaskProgressDialogState>();
    final items = [
      TaskProgressItem(
        title: result.courseTitle,
        subtitle: 'paperId=${result.paperId}',
        state: PlaybackState.playing,
        progress: 0.0,
        message: '提交$typeLabel中...',
      ),
    ];
    var stopped = false;
    TaskProgressDialog.show(
      context,
      items: items,
      logStream: service.logStream,
      title: '提交$typeLabel',
      dialogKey: dialogKey,
      onStop: () {
        stopped = true;
        service.cancel();
      },
    );

    // 3. 执行提交
    SubmitResult submitResult;
    try {
      submitResult = await service.submit(
        result: effectiveResult,
        type: type,
        selectedQuestions: selectedQuestions,
        imageUploadConfig: imageUploadConfig,
      );
    } catch (e) {
      submitResult = SubmitResult(
        success: false,
        message: '提交异常: $e',
        submittedCount: 0,
        type: type,
      );
    }
    service.dispose();

    // 4. 更新进度项状态 (供弹窗"进度"标签实时显示)
    items[0].state =
        submitResult.success ? PlaybackState.completed : PlaybackState.failed;
    items[0].progress = 1.0;
    items[0].message = submitResult.message;

    // 5. 标记完成: 弹窗按钮由"停止"变"关闭", 用户可查看日志后手动关闭
    if (!stopped) {
      dialogKey.currentState?.markFinished();
      _showSubmitSnackBar(submitResult);
    }
  }

  /// 批量提交全部课程答案, 带"批量配置弹窗"+"进度/日志弹窗"
  ///
  /// 每个课程提交其全部题目 (不做题型过滤), 图片上传方案统一配置。
  /// 所有课程共享同一 [AnswerSubmitService] 的日志流与取消标志,
  /// 在 [TaskProgressDialog] 中逐课程推进进度。
  Future<void> _submitBatch(SubmitType type) async {
    final results = widget.results;
    if (results.isEmpty) return;
    final service = _buildSubmitService();

    final typeLabel = type == SubmitType.trace ? '做题痕迹' : '作答结果';

    // 1. 批量提交配置弹窗 (图片上传方案 + 课程清单 + 确认)
    ImageUploadConfig? imageUploadConfig = _imageUploadConfig;
    bool imageUploadEnabled = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => BatchSubmitConfigDialog(
        results: results,
        type: type,
        initialImageUploadConfig: _imageUploadConfig,
        onConfirm: (cfg, enabled) async {
          if (cfg != null) {
            _imageUploadConfig = cfg;
            imageUploadConfig = cfg;
          }
          imageUploadEnabled = enabled;
          Navigator.of(context).pop(true);
        },
      ),
    );
    if (confirmed != true || !mounted) {
      service.dispose();
      return;
    }
    final effectiveConfig = imageUploadEnabled ? imageUploadConfig : null;

    // 2. 进度/日志弹窗: 每个课程一个进度项
    final dialogKey = GlobalKey<TaskProgressDialogState>();
    final items = results
        .map((r) => TaskProgressItem(
              title: r.courseTitle,
              subtitle: 'paperId=${r.paperId}',
              state: PlaybackState.initializing,
              progress: 0.0,
            ))
        .toList();
    var stopped = false;
    TaskProgressDialog.show(
      context,
      items: items,
      logStream: service.logStream,
      title: '批量提交$typeLabel',
      dialogKey: dialogKey,
      onStop: () {
        stopped = true;
        service.cancel();
      },
    );

    // 3. 逐课程提交 (顺序执行, 共享同一服务的日志流与取消标志)
    int successCount = 0;
    int failCount = 0;
    for (int i = 0; i < results.length; i++) {
      if (stopped) break;
      final r = results[i];
      // 跳过缺少 reportId 的课程 (无法提交)
      if (r.reportId.isEmpty) {
        items[i].state = PlaybackState.failed;
        items[i].progress = 1.0;
        items[i].message = '缺少 reportId, 跳过';
        failCount++;
        continue;
      }
      items[i].state = PlaybackState.playing;
      items[i].progress = 0.1;
      items[i].message = '提交$typeLabel中...';

      SubmitResult sr;
      try {
        sr = await service.submit(
          result: r,
          type: type,
          selectedQuestions: r.questions,
          imageUploadConfig: effectiveConfig,
        );
      } catch (e) {
        sr = SubmitResult(
          success: false,
          message: '提交异常: $e',
          submittedCount: 0,
          type: type,
        );
      }
      items[i].state =
          sr.success ? PlaybackState.completed : PlaybackState.failed;
      items[i].progress = 1.0;
      items[i].message = sr.message;
      if (sr.success) {
        successCount++;
      } else {
        failCount++;
      }
    }
    service.dispose();

    // 4. 标记完成 + 摘要
    if (!stopped) {
      dialogKey.currentState?.markFinished();
      if (mounted) {
        final total = results.length;
        final allOk = failCount == 0;
        final partial = successCount > 0 && failCount > 0;
        final msg = allOk
            ? '全部 $total 个课程$typeLabel提交成功'
            : (partial
                ? '部分成功: 成功 $successCount, 失败 $failCount (共 $total)'
                : '全部 $failCount 个课程提交失败');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: allOk ? 3 : 6),
            backgroundColor: allOk
                ? Colors.green.shade700
                : (partial ? Colors.orange.shade700 : Colors.red.shade700),
          ),
        );
      }
    }
  }

  /// 显示单次提交结果 SnackBar
  void _showSubmitSnackBar(SubmitResult r) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(r.message),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: r.success ? 3 : 5),
        backgroundColor:
            r.success ? Colors.green.shade700 : Colors.red.shade700,
      ),
    );
  }

  Future<void> _onExportSelected(String value) async {
    switch (value) {
      case 'current':
        await _exportCurrent();
        break;
      case 'all':
        await _exportAll();
        break;
      case 'single_each':
        await _exportEach();
        break;
      case 'config':
        _showExportConfig();
        break;
    }
  }

  /// 导出当前课程
  Future<void> _exportCurrent() async {
    final index = _tabController.index;
    if (index >= widget.results.length) return;
    final result = widget.results[index];
    setState(() => _exporting = true);
    try {
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final saveDir = Directory('${dir.path}/EwtAutoClient/试题答案');
      if (!saveDir.existsSync()) saveDir.createSync(recursive: true);
      final filename =
          '${_sanitizeFilename(_applyFilenameRule(result, _filenameRule))}.pdf';
      final filepath = '${saveDir.path}/$filename';
      final ok = await PaperPdfExporter.export(
        result,
        filepath,
        includeAnswer: true,
        docTitle: result.courseTitle,
        showSuccess: true,
        fields: _buildExportFields(),
        fontConfig: _fontConfig,
      );
      _showExportResult(ok, filepath);
    } catch (e) {
      _showExportResult(false, '$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 导出全部课程 (合并为一个 PDF)
  Future<void> _exportAll() async {
    setState(() => _exporting = true);
    try {
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final saveDir = Directory('${dir.path}/EwtAutoClient/试题答案');
      if (!saveDir.existsSync()) saveDir.createSync(recursive: true);
      final filename = widget.results.length == 1
          ? _applyFilenameRule(widget.results.first, _filenameRule)
          : '批量答案-${_todayStr()}';
      final filepath = '${saveDir.path}/${_sanitizeFilename(filename)}.pdf';
      final ok = await PaperPdfExporter.exportBatch(
        widget.results,
        filepath,
        includeAnswer: true,
        docTitle: '试题答案 (${widget.results.length} 课程)',
        showSuccess: true,
        fields: _buildExportFields(),
        fontConfig: _fontConfig,
      );
      _showExportResult(ok, filepath);
    } catch (e) {
      _showExportResult(false, '$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 每课程单文件导出
  Future<void> _exportEach() async {
    setState(() => _exporting = true);
    try {
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final saveDir = Directory('${dir.path}/EwtAutoClient/试题答案');
      if (!saveDir.existsSync()) saveDir.createSync(recursive: true);
      int success = 0;
      for (final result in widget.results) {
        final filename =
            '${_sanitizeFilename(_applyFilenameRule(result, _filenameRule))}.pdf';
        final filepath = '${saveDir.path}/$filename';
        final ok = await PaperPdfExporter.export(
          result,
          filepath,
          includeAnswer: true,
          docTitle: result.courseTitle,
          showSuccess: true,
          fields: _buildExportFields(),
          fontConfig: _fontConfig,
        );
        if (ok) success++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已导出 $success/${widget.results.length} 个文件至 ${saveDir.path}'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      _showExportResult(false, '$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _showExportConfig() {
    showDialog(
      context: context,
      builder: (_) => _ExportConfigDialog(
        initialRule: _filenameRule,
        initialFields: _exportFields,
        initialFontConfig: _fontConfig,
        onSaved: (rule, fields, fontConfig) {
          setState(() {
            _filenameRule = rule;
            _exportFields = fields;
            _fontConfig = fontConfig;
          });
        },
      ),
    );
  }

  // ─── 导出配置状态 ───
  String _filenameRule = '{课程名称}';
  AnswerExportFields _exportFields = const AnswerExportFields();
  ExportFontConfig _fontConfig = const ExportFontConfig();

  // ─── 图片上传配置状态 (在多次提交之间保留用户选择) ───
  ImageUploadConfig _imageUploadConfig = const ImageUploadConfig();

  AnswerExportFields _buildExportFields() => _exportFields;

  void _showExportResult(bool ok, String path) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已导出: $path' : '导出失败: $path'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: ok ? 3 : 5),
        action: ok
            ? SnackBarAction(
                label: '打开目录',
                onPressed: () {
                  // 打开文件所在目录 (Windows)
                  if (Platform.isWindows) {
                    Process.run('explorer.exe',
                        ['/select,', path.replaceAll('/', '\\')]);
                  }
                },
              )
            : null,
      ),
    );
  }

  /// 应用文件名规则
  ///
  /// 支持占位符: {课程名称} {课程日期} {课程学科} {课程类型}
  String _applyFilenameRule(CourseAnswerResult r, String rule) {
    return rule
        .replaceAll('{课程名称}', r.courseTitle)
        .replaceAll('{课程日期}', r.dateLabel.isNotEmpty ? r.dateLabel : '')
        .replaceAll('{课程学科}', r.subjectName)
        .replaceAll('{课程类型}', r.method);
  }

  String _sanitizeFilename(String name) {
    final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return sanitized.isEmpty ? '未命名' : sanitized;
  }

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}

/// 导出配置弹窗
class _ExportConfigDialog extends StatefulWidget {
  final String initialRule;
  final AnswerExportFields initialFields;
  final ExportFontConfig initialFontConfig;
  final void Function(
      String rule, AnswerExportFields fields, ExportFontConfig fontConfig) onSaved;

  const _ExportConfigDialog({
    required this.initialRule,
    required this.initialFields,
    required this.initialFontConfig,
    required this.onSaved,
  });

  @override
  State<_ExportConfigDialog> createState() => _ExportConfigDialogState();
}

class _ExportConfigDialogState extends State<_ExportConfigDialog> {
  late String _rule;
  late bool _showQuestionContent;
  late bool _showOptions;
  late bool _showAnswer;
  late bool _showKnowledge;
  late bool _showDifficulty;
  late bool _showAnalysis;

  // ─── 字体配置 ───
  late ExportFontType _fontType;
  late String _bundledName;
  late String _customFontPath;

  @override
  void initState() {
    super.initState();
    _rule = widget.initialRule;
    _showQuestionContent = widget.initialFields.showQuestionContent;
    _showOptions = widget.initialFields.showOptions;
    _showAnswer = widget.initialFields.showAnswer;
    _showKnowledge = widget.initialFields.showKnowledge;
    _showDifficulty = widget.initialFields.showDifficulty;
    _showAnalysis = widget.initialFields.showAnalysis;
    _fontType = widget.initialFontConfig.type;
    _bundledName = widget.initialFontConfig.bundledName;
    _customFontPath = widget.initialFontConfig.customFontPath;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('导出配置'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('文件名规则',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '可用占位符: {课程名称} {课程日期} {课程学科}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              // TextFormField.initialValue 只在首次构建取值, 避免每次重建
              // 新建 TextEditingController 造成泄漏。
              TextFormField(
                initialValue: _rule,
                decoration: const InputDecoration(
                  hintText: '{课程日期}-{课程学科}-{课程名称}',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => _rule = v,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                children: [
                  _chip('{课程名称}'),
                  _chip('{课程日期}'),
                  _chip('{课程学科}'),
                ],
              ),
              const Divider(height: 24),
              Text('导出字段',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _toggle('原题目', _showQuestionContent,
                  (v) => setState(() => _showQuestionContent = v)),
              _toggle('选项', _showOptions, (v) => setState(() => _showOptions = v)),
              _toggle('答案', _showAnswer, (v) => setState(() => _showAnswer = v)),
              _toggle('知识点', _showKnowledge,
                  (v) => setState(() => _showKnowledge = v)),
              _toggle('题目难度', _showDifficulty,
                  (v) => setState(() => _showDifficulty = v)),
              _toggle('解析', _showAnalysis,
                  (v) => setState(() => _showAnalysis = v)),
              const Divider(height: 24),
              // ─── PDF 字体 ───
              Text('PDF 字体',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '导出 PDF 使用的字体, 影响中文显示效果',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              RadioGroup<ExportFontType>(
                groupValue: _fontType,
                onChanged: (v) {
                  if (v != null) setState(() => _fontType = v);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<ExportFontType>(
                      title: const Text('内置字体'),
                      subtitle: Text(
                        _bundledLabel(),
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: ExportFontType.bundled,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile<ExportFontType>(
                      title: const Text('系统字体'),
                      subtitle: const Text(
                        '从系统字体目录加载 (Windows: simhei, Android: NotoSansCJK)',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: ExportFontType.system,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile<ExportFontType>(
                      title: const Text('自定义 TTF 文件'),
                      subtitle: Text(
                        _customFontPath.isEmpty
                            ? '未选择文件'
                            : _customFontPath,
                        style: const TextStyle(fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: ExportFontType.custom,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              if (_fontType == ExportFontType.custom)
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _pickCustomFont,
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                      label: const Text('选择 TTF 文件'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            widget.onSaved(
              _rule.isEmpty ? '{课程名称}' : _rule,
              AnswerExportFields(
                showQuestionContent: _showQuestionContent,
                showOptions: _showOptions,
                showAnswer: _showAnswer,
                showKnowledge: _showKnowledge,
                showDifficulty: _showDifficulty,
                showAnalysis: _showAnalysis,
              ),
              _buildFontConfig(),
            );
            Navigator.pop(context);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  /// 构建当前字体配置
  ExportFontConfig _buildFontConfig() {
    return ExportFontConfig(
      type: _fontType,
      bundledName: _bundledName,
      customFontPath: _customFontPath,
    );
  }

  /// 内置字体显示标签
  String _bundledLabel() {
    final opt = BundledFontOption.all
        .where((o) => o.name == _bundledName)
        .firstOrNull;
    return opt?.label ?? 'HarmonyOS Sans SC (鸿蒙黑体)';
  }

  /// 选择自定义 TTF 字体文件
  Future<void> _pickCustomFont() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf'],
      withData: false,
    );
    if (result != null && result.files.single.path != null) {
      setState(() => _customFontPath = result.files.single.path!);
    }
  }

  Widget _chip(String label) {
    return ActionChip(
      label: Text(label),
      onPressed: () => setState(() => _rule = '$_rule$label'),
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    return CheckboxListTile(
      title: Text(label),
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}

/// 单个课程的答案展示视图
class _CourseAnswerView extends StatelessWidget {
  final CourseAnswerResult result;
  final AnswerConfig config;

  const _CourseAnswerView({required this.result, required this.config});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 课程信息卡
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        result.courseTitle,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${result.successCount}/${result.totalCount}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 12,
                  children: [
                    if (result.subjectName.isNotEmpty)
                      _metaChip(theme, '学科', result.subjectName),
                    if (result.dateLabel.isNotEmpty)
                      _metaChip(theme, '日期', result.dateLabel),
                    _metaChip(theme, '方案', result.method),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 题目列表
        ...result.questions.map((q) => _QuestionCard(
              question: q,
              config: config,
              isChild: false,
            )),
        if (result.questions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                '未获取到题目答案',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
      ],
    );
  }

  Widget _metaChip(ThemeData theme, String label, String value) {
    return Text(
      '$label: $value',
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

/// 单题卡片
class _QuestionCard extends StatelessWidget {
  final QuestionInfo question;
  final AnswerConfig config;
  final bool isChild;

  const _QuestionCard({
    required this.question,
    required this.config,
    required this.isChild,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasChildren = question.childQuestions.isNotEmpty;
    // 父题有子题时, 答案/知识点/解析在子题中展示, 父题仅展示题干
    final skipAnswerFields = hasChildren;

    return Container(
      margin: EdgeInsets.only(
          bottom: isChild ? 8 : 12, left: isChild ? 16 : 0),
      padding: const EdgeInsets.all(12),
      decoration: isChild
          ? BoxDecoration(
              border: Border(
                left: BorderSide(width: 3, color: theme.dividerColor),
              ),
            )
          : BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.dividerColor),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 题号 + 题型 + 难度
          if (question.number.isNotEmpty ||
              (config.showDifficulty && question.difficulty.isNotEmpty) ||
              question.questionType.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (question.number.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        question.number,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (question.questionType.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        question.questionType,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  if (config.showDifficulty &&
                      question.difficulty.isNotEmpty)
                    Text(
                      question.difficulty,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (question.group.isNotEmpty)
                    Text(
                      '[${question.group}]',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          // 题干 (HTML 渲染)
          if (config.showQuestionContent &&
              question.questionContent.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Html(
                data: question.questionContent,
                style: ewtHtmlStyle(theme),
                extensions: buildEwtHtmlExtensions(),
                shrinkWrap: true,
              ),
            ),
          // 选项
          if (config.showOptions && question.options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: question.options
                    .map((opt) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Html(
                            data: opt,
                            style: ewtHtmlStyle(theme),
                            extensions: buildEwtHtmlExtensions(),
                            shrinkWrap: true,
                          ),
                        ))
                    .toList(),
              ),
            ),
          // 答案
          if (!skipAnswerFields &&
              config.showAnswer &&
              question.answer.isNotEmpty)
            _LabeledField(
              label: '答案',
              color: Colors.green,
              child: _AnswerContent(answer: question.answer, theme: theme),
            ),
          // 知识点
          if (!skipAnswerFields &&
              config.showKnowledge &&
              question.knowledge.isNotEmpty)
            _LabeledField(
              label: '知识点',
              color: Colors.purple,
              child: Text(
                question.knowledge,
                style: theme.textTheme.bodySmall,
              ),
            ),
          // 解析 (HTML 渲染)
          if (!skipAnswerFields &&
              config.showAnalysis &&
              question.analysis.isNotEmpty)
            _LabeledField(
              label: '解析',
              color: Colors.orange,
              child: Html(
                data: question.analysis,
                style: ewtHtmlStyle(theme),
                extensions: buildEwtHtmlExtensions(),
                shrinkWrap: true,
              ),
            ),
          // 子题
          if (hasChildren) ...[
            const SizedBox(height: 6),
            ...question.childQuestions.map((cq) => _QuestionCard(
                  question: cq,
                  config: config,
                  isChild: true,
                )),
          ],
        ],
      ),
    );
  }
}

/// 带标签的字段行
class _LabeledField extends StatelessWidget {
  final String label;
  final Color color;
  final Widget child;

  const _LabeledField({
    required this.label,
    required this.color,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            margin: const EdgeInsets.only(top: 2, right: 8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color.withValues(alpha: 0.9),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 答案内容 (客观题纯文本, 主观题 HTML)
class _AnswerContent extends StatelessWidget {
  final String answer;
  final ThemeData theme;

  const _AnswerContent({required this.answer, required this.theme});

  @override
  Widget build(BuildContext context) {
    final isObjective = RegExp(r'^[A-Z](,\s*[A-Z])*$').hasMatch(answer);
    final hasHtml = answer.contains('<') && answer.contains('>');
    if (isObjective) {
      return Text(
        answer,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: Colors.green.shade700,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (hasHtml) {
      return Html(
        data: answer,
        style: ewtHtmlStyle(theme),
        extensions: buildEwtHtmlExtensions(),
        shrinkWrap: true,
      );
    }
    return Text(answer, style: theme.textTheme.bodyMedium);
  }
}
