/// 手动填写提交页，面向下载方案（教师版 PDF 无法自动解析）：选择题点选、
/// 主观题相册选取/相机拍照/编辑器提交、其他题文本填写。
/// 确认后返回 ManualSubmitInput，由调用方复用 AnswerSubmitService 提交；支持双栏
/// 预览（下载方案为答案 PDF；试题答案页"手动提交"为已获取答案列表，不限获取方案）。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:image_picker/image_picker.dart';

import '../../domain/entities/image_upload_config.dart';
import '../../domain/entities/question_info.dart';
import '../../domain/services/answer_submit_service.dart';
import '../../presentation/widgets/ewt_html_render.dart';
import '../widgets/pdfrx_viewer.dart';
import '../../../editor/domain/entities/editor_config.dart';
import '../../../editor/domain/services/editor_export_service.dart';
import '../../../editor/presentation/editor_page.dart';

/// 手动提交配置结果
///
/// 由 [ManualAnswerSubmitPage] 确认后通过 Navigator.pop 返回:
/// - [questions]: 手动填写后的题目列表 (客观题 rightAnswerRaw 已按填写结果设置)
/// - [imageUploadConfig]: 主观题图片上传配置 (mode=custom + manual 分配)
/// - [reportId]: (可能手动补填的) 有效 reportId
class ManualSubmitInput {
  final List<QuestionInfo> questions;
  final ImageUploadConfig imageUploadConfig;
  final String reportId;

  const ManualSubmitInput({
    required this.questions,
    required this.imageUploadConfig,
    required this.reportId,
  });
}

/// 批量手动提交配置结果 (多试卷 TAB 模式)
///
/// 由 [ManualAnswerSubmitPage] 多试卷模式确认后通过 Navigator.pop 返回:
/// - [inputs]: 每份试卷对应一个 [ManualSubmitInput]
class ManualSubmitBatchInput {
  final List<ManualSubmitInput> inputs;

  const ManualSubmitBatchInput({required this.inputs});
}

/// 手动填写提交页
///
/// 面向"下载方案" (教师版 PDF 答案, 无法自动解析) 的提交:
/// 由于 PDF 答案不能回填到题目, 所有答案均由用户手动填写:
/// - 选择题 (有选项且非主观题): 点击选项选择 (支持多选)
/// - 主观题: 相册选取 / 相机拍照 / 画布编辑器提交 (支持单题多张)
/// - 其他客观题 (填空/判断等): 文本输入
///
/// 确认后返回 [ManualSubmitInput], 由调用方复用 [AnswerSubmitService] 提交。
///
/// [pdfBytes] 可选: 传入答案 PDF 字节后, 右上角提供"查看答案 PDF"入口,
/// 点击切换双栏布局 (左: pdfrx 内嵌答案预览 / 右: 本作答页),
/// 中间分界线支持鼠标/触屏拖拽调整宽度比例。
class ManualAnswerSubmitPage extends StatefulWidget {
  /// 单试卷模式: 课程答案结果 (题目来自下载方案独立取题接口 paperQuestionGroup)
  final CourseAnswerResult? result;

  /// 多试卷模式: 课程答案结果列表 (TAB 切换)
  final List<CourseAnswerResult>? results;

  /// 提交类型 (trace=做题痕迹 / result=答题结果)
  final SubmitType type;

  /// 答案 PDF 字节 (教师版), 用于双栏预览入口
  final Uint8List? pdfBytes;

  /// 多试卷模式: 每份试卷对应的 PDF 字节 (paperId → bytes)
  final Map<String, Uint8List>? pdfByPaperId;

  /// 是否显示提交范围选择弹窗 (仅提交试卷多课程时生效)
  final bool showScopeDialog;

  /// 是否提供"查看答案"双栏预览
  ///
  /// 供试题答案页"手动提交"入口使用: 此时 result.questions 已携带答案/解析,
  /// 打开后可像下载方案 (答案 PDF 预览) 一样边看答案边填写, 不限获取方案。
  final bool showAnswerPreview;

  const ManualAnswerSubmitPage({
    super.key,
    this.result,
    this.results,
    required this.type,
    this.pdfBytes,
    this.pdfByPaperId,
    this.showScopeDialog = false,
    this.showAnswerPreview = false,
  });

  /// 便捷构造: 单试卷模式
  const ManualAnswerSubmitPage.single({
    super.key,
    required CourseAnswerResult result,
    required this.type,
    this.pdfBytes,
    this.showScopeDialog = false,
    this.showAnswerPreview = false,
  })  : result = result,
        results = null,
        pdfByPaperId = null;

  /// 便捷构造: 多试卷模式
  const ManualAnswerSubmitPage.multi({
    super.key,
    required List<CourseAnswerResult> results,
    required this.type,
    this.pdfByPaperId,
    this.showScopeDialog = false,
    this.showAnswerPreview = false,
  })  : result = null,
        this.results = results,
        pdfBytes = null;

  /// 是否为多试卷模式
  bool get isMultiMode => results != null && results!.length > 1;

  @override
  State<ManualAnswerSubmitPage> createState() => _ManualAnswerSubmitPageState();
}

/// 单题填写状态
class _QuestionEntry {
  final QuestionInfo q;

  /// 是否参与提交
  bool included;

  /// 选择题: 选中的选项索引
  final Set<int> selectedOptions = {};

  /// 填空题: 文本答案
  String textAnswer = '';

  /// 主观题: 上传的图片 (单题多张)
  final List<Uint8List> imageBytes = [];
  final List<String> imageNames = [];

  /// 主观题: 画布编辑器提交内容 (组件式画布, 可再编辑)
  ///
  /// 以 [EditorConfig] 承载文本/图片/公式/涂鸦组件, 关闭编辑器后导出的 PNG
  /// 字节缓存于 [editorPng], 用于提交流程作为附件; [editorConfig] 保留以便
  /// 下次进入同一题继续编辑画布。
  EditorConfig? editorConfig;
  Uint8List? editorPng;

  _QuestionEntry(this.q, {this.included = true});
}

/// 单份试卷的填写状态
class _PaperState {
  final CourseAnswerResult result;
  late final List<_QuestionEntry> entries;
  late final List<_ListRow> rows;
  late final TextEditingController reportIdController;

  _PaperState(this.result) {
    entries = [];
    rows = [];
    // 分组题: 先展示材料题干行, 再逐子题行;
    // 普通题: 直接作为可提交行
    for (final q in result.questions) {
      if (q.childQuestions.isNotEmpty) {
        rows.add(_GroupRow(q));
        for (final child in q.childQuestions) {
          final e = _QuestionEntry(child, included: child.id.isNotEmpty);
          entries.add(e);
          rows.add(_QuestionRow(e));
        }
      } else {
        final e = _QuestionEntry(q, included: q.id.isNotEmpty);
        entries.add(e);
        rows.add(_QuestionRow(e));
      }
    }
    reportIdController = TextEditingController(text: result.reportId);
  }
}

class _ManualAnswerSubmitPageState extends State<ManualAnswerSubmitPage>
    with SingleTickerProviderStateMixin {
  /// 当前选中的试卷索引 (多试卷模式)
  int _currentPaperIndex = 0;

  /// 多试卷模式: 每份试卷的状态
  late final List<_PaperState> _paperStates;

  /// 当前试卷的可提交题目 (单试卷模式兼容)
  late final List<_QuestionEntry> _entries;

  /// 当前试卷的列表展示行 (单试卷模式兼容)
  late final List<_ListRow> _rows;

  /// 当前试卷的 reportId 控制器 (单试卷模式兼容)
  late final TextEditingController _reportIdController;

  /// 是否展开双栏 (左 PDF 预览 / 右作答)
  bool _showPdf = false;

  /// 双栏左侧 (PDF) 宽度占比, 范围见 [_minFraction]/[_maxFraction]
  double _leftFraction = 0.5;

  /// 左侧栏最小/最大占比, 防止任一栏被完全压扁
  static const double _minFraction = 0.25;
  static const double _maxFraction = 0.8;

  /// 多试卷模式下是否已初始化
  bool get _isMultiMode => widget.isMultiMode;

  @override
  void initState() {
    super.initState();
    if (_isMultiMode) {
      // 多试卷模式: 初始化所有试卷状态
      _paperStates = widget.results!.map((r) => _PaperState(r)).toList();
      // 初始化当前试卷的引用
      _entries = _paperStates[0].entries;
      _rows = _paperStates[0].rows;
      _reportIdController = _paperStates[0].reportIdController;
    } else {
      // 单试卷模式: 只有一份试卷
      final state = _PaperState(widget.result!);
      _paperStates = [state];
      _entries = state.entries;
      _rows = state.rows;
      _reportIdController = state.reportIdController;
    }
  }

  @override
  void dispose() {
    for (final state in _paperStates) {
      state.reportIdController.dispose();
    }
    super.dispose();
  }

  /// 切换到指定试卷
  void _switchToPaper(int index) {
    if (index == _currentPaperIndex || index < 0 || index >= _paperStates.length) {
      return;
    }
    setState(() {
      _currentPaperIndex = index;
      // 更新引用到新试卷的状态
      final state = _paperStates[index];
      _entries = state.entries;
      _rows = state.rows;
      _reportIdController = state.reportIdController;
      _showPdf = false;
    });
  }

  bool _isChoice(_QuestionEntry e) =>
      !e.q.subjective && e.q.options.isNotEmpty;

  bool _isSubjective(_QuestionEntry e) => e.q.subjective;

  /// 有效 reportId (自动 + 手动)
  String get _effectiveReportId => _reportIdController.text.trim();

  /// 已参与提交的题目数
  int get _includedCount => _entries.where((e) => e.included).length;

  /// 已填写的题目数 (选择题有选项 / 主观题有图 / 文本题有文字)
  int get _filledCount => _entries.where((e) {
        if (!e.included) return false;
        if (_isChoice(e)) return e.selectedOptions.isNotEmpty;
        if (_isSubjective(e)) {
          return e.imageBytes.isNotEmpty || e.editorConfig != null;
        }
        return e.textAnswer.trim().isNotEmpty;
      }).length;

  /// 从选项字符串提取选项字母 ("A. xxx" → "A")
  static String _optionLetter(String opt, int index) {
    final trimmed = opt.trim();
    if (trimmed.isEmpty) return String.fromCharCode(65 + index);
    final m = RegExp(r'^([A-Za-z])(?=[.\s、）)]|$)').firstMatch(trimmed);
    if (m != null) return m.group(1)!.toUpperCase();
    return String.fromCharCode(65 + index);
  }

  /// 构建手动填写后的题目副本 (设置 rightAnswerRaw)
  QuestionInfo _filled(QuestionInfo q, List<String> answers) {
    return QuestionInfo(
      number: q.number,
      group: q.group,
      answer: q.answer,
      analysis: q.analysis,
      knowledge: q.knowledge,
      questionType: q.questionType,
      questionContent: q.questionContent,
      options: q.options,
      childQuestions: q.childQuestions,
      difficulty: q.difficulty,
      id: q.id,
      cate: q.cate,
      subjective: q.subjective,
      questionNoShow: q.questionNoShow,
      questionSort: q.questionSort,
      parentId: q.parentId,
      rightAnswerRaw: answers,
    );
  }

  Future<void> _onConfirm() async {
    // 多课程模式下显示提交范围选择弹窗
    if (widget.showScopeDialog && _isMultiMode) {
      final scope = await _showSubmitScopeDialog();
      if (scope == null) return; // 用户取消
      if (scope == 'current') {
        // 仅当前课程: 只提交当前 TAB 的试卷
        await _submitCurrentPaper();
        return;
      }
      // 全部选择课程: 继续下面的全部提交逻辑
    }

    if (_isMultiMode) {
      // 多试卷模式: 收集所有试卷的填写结果
      final inputs = <ManualSubmitInput>[];
      for (int i = 0; i < _paperStates.length; i++) {
        final state = _paperStates[i];
        final included = state.entries.where((e) => e.included).toList();
        final reportId = state.reportIdController.text.trim();

        // 跳过空试卷 (无题目或无 reportId)
        if (included.isEmpty || reportId.isEmpty) continue;

        // 预先导出画布 PNG
        for (final e in included) {
          if (e.editorConfig != null && e.editorPng == null) {
            e.editorPng = await EditorExportService.instance
                .exportPng(context, e.editorConfig!);
          }
        }
        if (!mounted) return;

        inputs.add(_buildInput(included, reportId));
      }

      if (inputs.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('没有可提交的试卷 (缺少题目或 reportId)')),
        );
        return;
      }

      Navigator.of(context).pop(ManualSubmitBatchInput(inputs: inputs));
    } else {
      // 单试卷模式: 原有逻辑
      final included = _entries.where((e) => e.included).toList();
      if (included.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('请至少选择一道题')),
        );
        return;
      }
      if (_effectiveReportId.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('缺少 reportId, 无法提交')),
        );
        return;
      }

      // 预先导出画布 PNG
      for (final e in included) {
        if (e.editorConfig != null && e.editorPng == null) {
          e.editorPng = await EditorExportService.instance
              .exportPng(context, e.editorConfig!);
        }
      }
      if (!mounted) return;

      Navigator.of(context).pop(_buildInput(included, _effectiveReportId));
    }
  }

  /// 显示提交范围选择弹窗
  Future<String?> _showSubmitScopeDialog() async {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提交范围'),
        content: const Text('请选择提交范围'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('current'),
            child: const Text('仅当前课程'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('all'),
            child: const Text('全部选择课程'),
          ),
        ],
      ),
    );
  }

  /// 仅提交当前课程
  Future<void> _submitCurrentPaper() async {
    final state = _paperStates[_currentPaperIndex];
    final included = state.entries.where((e) => e.included).toList();
    final reportId = state.reportIdController.text.trim();

    if (included.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('请至少选择一道题')),
      );
      return;
    }
    if (reportId.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('缺少 reportId, 无法提交')),
      );
      return;
    }

    // 预先导出画布 PNG
    for (final e in included) {
      if (e.editorConfig != null && e.editorPng == null) {
        e.editorPng = await EditorExportService.instance
            .exportPng(context, e.editorConfig!);
      }
    }
    if (!mounted) return;

    // 返回单份试卷结果, 用 ManualSubmitBatchInput 包装以便统一处理
    Navigator.of(context).pop(
      ManualSubmitBatchInput(inputs: [_buildInput(included, reportId)]),
    );
  }

  /// 构建单份试卷的 ManualSubmitInput
  ManualSubmitInput _buildInput(List<_QuestionEntry> included, String reportId) {
    final questions = <QuestionInfo>[];
    final manualBytes = <String, List<Uint8List>>{};
    final manualNames = <String, List<String>>{};

    for (final e in included) {
      if (_isChoice(e)) {
        // 选择题: 答案 = 选中选项的字母列表 (如 ["A","B"])
        final letters = e.selectedOptions.toList()..sort();
        questions.add(_filled(
          e.q,
          letters.map((i) => _optionLetter(e.q.options[i], i)).toList(),
        ));
      } else if (_isSubjective(e)) {
        // 主观题: 图片上传 (单题多张) 和/或 画布编辑器提交
        questions.add(_filled(e.q, const <String>[]));
        final allBytes = <Uint8List>[...e.imageBytes];
        final allNames = <String>[...e.imageNames];
        if (e.editorPng != null) {
          allBytes.add(e.editorPng!);
          allNames.add('editor_${e.q.id}.png');
        }
        if (allBytes.isNotEmpty) {
          manualBytes[e.q.id] = List<Uint8List>.from(allBytes);
          manualNames[e.q.id] = List<String>.from(allNames);
        }
      } else {
        // 其他客观题: 文本答案
        questions.add(_filled(e.q, [e.textAnswer.trim()]));
      }
    }

    return ManualSubmitInput(
      questions: questions,
      imageUploadConfig: manualBytes.isEmpty
          ? const ImageUploadConfig(
              mode: ImageUploadMode.custom,
              customAssignment: CustomImageAssignment.manual,
            )
          : ImageUploadConfig(
              mode: ImageUploadMode.custom,
              customAssignment: CustomImageAssignment.manual,
              manualImageBytes: manualBytes,
              manualImageNames: manualNames,
            ),
      reportId: reportId,
    );
  }

  /// 为指定主观题选择多张图片
  Future<void> _pickImages(_QuestionEntry e) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    setState(() {
      for (final f in result.files) {
        final b = f.bytes;
        if (b != null && b.isNotEmpty) {
          e.imageBytes.add(b);
          e.imageNames.add(f.name.isNotEmpty ? f.name : 'q_${e.imageBytes.length}.png');
        }
      }
    });
  }

  /// 相机拍照: 调系统相机拍摄一张照片, 追加到该主观题的图片列表 (可多次连拍)
  ///
  /// image_picker 在 Android/iOS 走系统相机 App (无需应用内相机权限);
  /// Windows 等桌面端不支持相机源, 异常时提示改用相册选取。
  Future<void> _captureCamera(_QuestionEntry e) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) return;
      if (!mounted) return;
      setState(() {
        e.imageBytes.add(bytes);
        e.imageNames.add('camera_${DateTime.now().millisecondsSinceEpoch}.jpg');
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('当前平台不支持相机拍照，请使用相册选取')),
      );
    }
  }

  /// 打开画布编辑器 (组件式: 文本/图片/公式/涂鸦)
  ///
  /// 返回的 [EditorConfig] 存回该主观题, 可再次进入继续编辑; 同时导出 PNG
  /// 字节缓存于 [ _QuestionEntry.editorPng ], 用于提交流程作为附件。
  Future<void> _openEditor(_QuestionEntry e) async {
    final result = await Navigator.of(context).push<EditorConfig?>(
      MaterialPageRoute(
        builder: (_) => EditorPage(
          initial: e.editorConfig ?? const EditorConfig(),
          onConfirm: (_) {},
        ),
      ),
    );
    if (result == null) return;
    // 导出 PNG 用于提交 (失败也保留 config 以便再编辑)
    final png = await EditorExportService.instance.exportPng(context, result);
    if (!mounted) return;
    setState(() {
      e.editorConfig = result;
      e.editorPng = png;
    });
  }

  /// 去除 HTML 标签, 便于纯文本展示
  static String _stripHtml(String html) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isMultiMode) {
      // 多试卷模式: 显示 TAB 切换
      return DefaultTabController(
        length: widget.results!.length,
        initialIndex: _currentPaperIndex,
        child: Builder(
          builder: (context) {
            final tabController = DefaultTabController.of(context);
            // 监听 TAB 切换
            tabController.addListener(() {
              if (!tabController.indexIsChanging) {
                _switchToPaper(tabController.index);
              }
            });

            return Scaffold(
              appBar: AppBar(
                title: Text('手动填写 · ${widget.results!.length} 份试卷'),
                actions: [
                  // 右上角"查看答案"入口: 试题答案页手动提交时, 已获取答案可预览
                  if (widget.showAnswerPreview)
                    IconButton(
                      icon: Icon(
                        Icons.lightbulb_outline,
                        color: _showPdf ? theme.colorScheme.primary : null,
                      ),
                      tooltip: _showPdf ? '收起答案预览' : '查看答案',
                      onPressed: () => setState(() => _showPdf = !_showPdf),
                    ),
                ],
                bottom: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  onTap: (index) => _switchToPaper(index),
                  tabs: [
                    for (int i = 0; i < widget.results!.length; i++)
                      Tab(
                        child: _buildTabContent(
                          theme,
                          widget.results![i],
                          i,
                        ),
                      ),
                  ],
                ),
              ),
              body: TabBarView(
                children: [
                  for (int i = 0; i < widget.results!.length; i++)
                    (_showPdf && widget.showAnswerPreview)
                        ? _buildDualPane(
                            theme,
                            _buildPaperContent(theme, i),
                            previewResult: _paperStates[i].result,
                          )
                        : _buildPaperContent(theme, i),
                ],
              ),
            );
          },
        ),
      );
    }

    // 单试卷模式: 原有逻辑
    return Scaffold(
      appBar: AppBar(
        title: Text('手动填写 · ${widget.result!.courseTitle}'),
        actions: [
          // 右上角预览入口: 答案 PDF (下载方案) 或已获取答案 (试题答案页手动提交)
          if (widget.pdfBytes != null || widget.showAnswerPreview)
            IconButton(
              icon: Icon(
                widget.pdfBytes != null
                    ? Icons.picture_as_pdf
                    : Icons.lightbulb_outline,
                color: _showPdf ? theme.colorScheme.primary : null,
              ),
              tooltip: !_showPdf
                  ? (widget.pdfBytes != null ? '查看答案 PDF' : '查看答案')
                  : '收起预览',
              onPressed: () => setState(() => _showPdf = !_showPdf),
            ),
        ],
      ),
      body: (widget.pdfBytes != null || widget.showAnswerPreview) && _showPdf
          ? _buildDualPane(theme, _buildAnswerPane(theme))
          : _buildAnswerPane(theme),
    );
  }

  /// 构建 TAB 内容 (试卷名称 + 填写进度)
  Widget _buildTabContent(ThemeData theme, CourseAnswerResult result, int index) {
    final state = _paperStates[index];
    final included = state.entries.where((e) => e.included).length;
    final filled = state.entries.where((e) {
      if (!e.included) return false;
      if (_isChoice(e)) return e.selectedOptions.isNotEmpty;
      if (_isSubjective(e)) {
        return e.imageBytes.isNotEmpty || e.editorConfig != null;
      }
      return e.textAnswer.trim().isNotEmpty;
    }).length;
    final hasReportId = state.reportIdController.text.trim().isNotEmpty;

    // 截取试卷名称 (避免 TAB 过长)
    var title = result.courseTitle;
    if (title.length > 12) {
      title = '${title.substring(0, 10)}...';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: index == _currentPaperIndex ? FontWeight.bold : FontWeight.normal,
            color: theme.textTheme.bodyMedium?.color,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          '$filled/$included',
          style: TextStyle(
            fontSize: 10,
            color: hasReportId
                ? (filled == included ? Colors.green : Colors.orange)
                : Colors.red,
          ),
        ),
      ],
    );
  }

  /// 构建指定试卷的内容面板
  Widget _buildPaperContent(ThemeData theme, int index) {
    final state = _paperStates[index];
    final result = state.result;
    final reportIdController = state.reportIdController;
    final entries = state.entries;
    final rows = state.rows;

    final typeLabel = widget.type == SubmitType.trace ? '提交做题痕迹' : '提交答题结果';
    final hasReportId = reportIdController.text.trim().isNotEmpty;

    // 计算填写进度
    final includedCount = entries.where((e) => e.included).length;
    final filledCount = entries.where((e) {
      if (!e.included) return false;
      if (_isChoice(e)) return e.selectedOptions.isNotEmpty;
      if (_isSubjective(e)) {
        return e.imageBytes.isNotEmpty || e.editorConfig != null;
      }
      return e.textAnswer.trim().isNotEmpty;
    }).length;

    return Column(
      children: [
        // 试卷信息
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          child: Row(
            children: [
              Icon(Icons.description_outlined, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.courseTitle,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'paperId: ${result.paperId}',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // reportId 补填
        if (!hasReportId)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: reportIdController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'reportId (缺少, 请手动填写)',
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '请输入 reportId',
              ),
            ),
          ),
        // 题目列表
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (context, rowIndex) {
              final row = rows[rowIndex];
              return switch (row) {
                _GroupRow(:final parent) => _buildGroupHeader(theme, parent),
                _QuestionRow(:final entry) => _buildQuestionCard(theme, entry),
              };
            },
          ),
        ),
        // 底部汇总 + 提交
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已选 $includedCount 题 · 已填 $filledCount 题'
                    '${includedCount > 0 && filledCount < includedCount ? " (有未填写题目)" : ""}',
                    style: TextStyle(
                      fontSize: 12,
                      color: filledCount == includedCount
                          ? Colors.blue
                          : Colors.orange[700],
                    ),
                  ),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.upload_outlined, size: 18),
                  label: Text(typeLabel),
                  onPressed: (hasReportId && includedCount > 0)
                      ? () => _onConfirmForPaper(index)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 单试卷模式下的确认操作
  void _onConfirmForPaper(int index) {
    // 切换到该试卷并执行确认
    if (index != _currentPaperIndex) {
      _switchToPaper(index);
    }
    _onConfirm();
  }

  /// 作答面板 (原页面主体: reportId 补填 + 题目列表 + 底部提交)
  Widget _buildAnswerPane(ThemeData theme) {
    final typeLabel =
        widget.type == SubmitType.trace ? '提交做题痕迹' : '提交答题结果';
    final hasReportId = _effectiveReportId.isNotEmpty;
    return Column(
      children: [
        // reportId: 原值缺失时手动补填
        if (!hasReportId)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _reportIdController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'reportId (缺少, 请手动填写)',
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '请输入 reportId',
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _rows.length,
            itemBuilder: (context, index) {
              final row = _rows[index];
              return switch (row) {
                _GroupRow(:final parent) => _buildGroupHeader(theme, parent),
                _QuestionRow(:final entry) =>
                  _buildQuestionCard(theme, entry),
              };
            },
          ),
        ),
        // 底部汇总 + 提交
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已选 $_includedCount 题 · 已填 $_filledCount 题'
                    '${_includedCount > 0 && _filledCount < _includedCount ? " (有未填写题目)" : ""}',
                    style: TextStyle(
                      fontSize: 12,
                      color: _filledCount == _includedCount
                          ? Colors.blue
                          : Colors.orange[700],
                    ),
                  ),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.upload_outlined, size: 18),
                  label: Text(typeLabel),
                  onPressed:
                      (hasReportId && _includedCount > 0) ? _onConfirm : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 双栏可拖拽布局
  ///
  /// 左: 答案预览 (答案 PDF / 已获取答案列表 [_AnswerPreviewPane]);
  /// 右: [rightPane] 作答面板。
  /// 中间分界线支持鼠标/触屏拖拽, 宽度占比限制在 [_minFraction]~[_maxFraction]。
  Widget _buildDualPane(
    ThemeData theme,
    Widget rightPane, {
    CourseAnswerResult? previewResult,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final leftWidth = maxWidth * _leftFraction;
        return Row(
          children: [
            // 左栏: 答案预览 (PDF 或已获取答案列表)
            SizedBox(
              width: leftWidth,
              child: widget.pdfBytes != null
                  ? PdfrxViewer(
                      bytes: widget.pdfBytes!,
                      sourceName: widget.result!.courseTitle,
                    )
                  : _AnswerPreviewPane(result: previewResult ?? widget.result!),
            ),
            // 中间可拖拽分界线 (鼠标 + 触屏)
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                // 拖拽时实时更新左侧占比; 同时支持鼠标与触屏 (pan)
                onPanUpdate: (d) {
                  setState(() {
                    final next = (maxWidth * _leftFraction + d.delta.dx) /
                        maxWidth;
                    _leftFraction = next.clamp(_minFraction, _maxFraction);
                  });
                },
                child: Container(
                  width: 10,
                  color: theme.dividerColor,
                  child: Center(
                    child: Icon(
                      Icons.drag_handle,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            // 右栏: 作答面板 (占据剩余宽度)
            Expanded(child: rightPane),
          ],
        );
      },
    );
  }

  Widget _buildQuestionCard(ThemeData theme, _QuestionEntry e) {
    final q = e.q;
    final label = q.questionNoShow.isNotEmpty
        ? q.questionNoShow
        : (q.number.isNotEmpty ? q.number : (q.id.isNotEmpty ? q.id : '?'));
    final typeLabel = q.questionType.isNotEmpty ? q.questionType : '';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部: 参与提交开关 + 题号 + 题型
            Row(
              children: [
                Checkbox(
                  value: e.included,
                  onChanged: (v) => setState(() => e.included = v ?? false),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '题 $label${typeLabel.isNotEmpty ? ' · $typeLabel' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (q.id.isEmpty)
                  Text('缺 id',
                      style: TextStyle(fontSize: 11, color: Colors.red[400])),
              ],
            ),
            // 题干 (富文本: 支持题目图片 / 公式渲染)
            if (_stripHtml(q.questionContent).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                child: _richHtml(q.questionContent, theme),
              ),
            // 填写区域
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _buildAnswerEditor(theme, e),
            ),
          ],
        ),
      ),
    );
  }

  /// 富文本渲染 (题干/选项): 支持题目图片、公式 (SVG Wirisformula)、表格等
  Widget _richHtml(String html, ThemeData theme) {
    if (html.trim().isEmpty) return const SizedBox.shrink();
    return Html(
      data: html,
      style: ewtHtmlStyle(theme),
      extensions: buildEwtHtmlExtensions(),
      shrinkWrap: true,
    );
  }

  /// 去除选项前坐标字母 (如 "A. xxx" → "xxx", 避免与字母列重复)
  static String _optionBody(String opt) {
    final trimmed = opt.trim();
    if (trimmed.isEmpty) return '';
    final m = RegExp(
      r'^([A-Za-z])[.\s、）)]+(.*)$',
      dotAll: true,
    ).firstMatch(trimmed);
    if (m != null) {
      final body = m.group(2)?.trim() ?? '';
      return body.isNotEmpty ? body : trimmed;
    }
    return trimmed;
  }

  /// 分组题材料题干行 (非提交项, 展示共享题干 + 题目图片/公式)
  Widget _buildGroupHeader(ThemeData theme, QuestionInfo parent) {
    final label = parent.questionNoShow.isNotEmpty ? parent.questionNoShow : '材料';
    final typeLabel = parent.questionType.isNotEmpty ? parent.questionType : '';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.forum_outlined,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '题 $label${typeLabel.isNotEmpty ? ' · $typeLabel' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _richHtml(parent.questionContent, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerEditor(ThemeData theme, _QuestionEntry e) {
    if (_isChoice(e)) {
      // 选择题: 展示完整选项内容 (题干), 点击整行快速勾选 (支持多选)
      final selected = e.selectedOptions;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < e.q.options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() {
                  if (selected.contains(i)) {
                    selected.remove(i);
                  } else {
                    selected.add(i);
                  }
                }),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      width: selected.contains(i) ? 1.5 : 1,
                      color: selected.contains(i)
                          ? theme.colorScheme.primary
                          : theme.dividerColor,
                    ),
                    color: selected.contains(i)
                        ? theme.colorScheme.primaryContainer
                            .withValues(alpha: 0.35)
                        : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        selected.contains(i)
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: selected.contains(i)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _optionLetter(e.q.options[i], i),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: selected.contains(i)
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        // 富文本选项: 支持选项图片 / 公式渲染
                        child: _richHtml(_optionBody(e.q.options[i]), theme),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '已选: ${selected.map((i) => _optionLetter(e.q.options[i], i)).join('、')}',
                style: TextStyle(fontSize: 12, color: Colors.blue[700]),
              ),
            ),
        ],
      );
    }

    if (_isSubjective(e)) {
      // 主观题: 相册选取 / 相机拍照 (主按钮) + 画布编辑器提交 (小图标按钮)
      final hasEditor = e.editorConfig != null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text(
                  e.imageBytes.isEmpty ? '相册选取' : '已选 ${e.imageBytes.length} 张',
                ),
                onPressed: () => _pickImages(e),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.photo_camera_outlined, size: 18),
                label: const Text('相机拍照'),
                onPressed: () => _captureCamera(e),
              ),
              IconButton(
                icon: Badge(
                  isLabelVisible: hasEditor,
                  child: const Icon(Icons.edit_note_outlined, size: 22),
                ),
                tooltip: hasEditor ? '编辑器提交 (已配置)' : '编辑器提交',
                color: hasEditor ? theme.colorScheme.primary : null,
                onPressed: () => _openEditor(e),
              ),
              if (e.imageBytes.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    e.imageBytes.clear();
                    e.imageNames.clear();
                  }),
                  child: const Text('清空图片'),
                ),
              if (hasEditor)
                TextButton(
                  onPressed: () => setState(() {
                    e.editorConfig = null;
                    e.editorPng = null;
                  }),
                  child: const Text('清空编辑器'),
                ),
            ],
          ),
          if (e.imageBytes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (int i = 0; i < e.imageBytes.length; i++)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(
                        e.imageBytes[i],
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                      ),
                    ),
                ],
              ),
            ),
          if (hasEditor && e.editorPng != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  e.editorPng!,
                  width: 96,
                  height: 128,
                  fit: BoxFit.cover,
                ),
              ),
            ),
        ],
      );
    }

    // 其他客观题: 文本输入
    // TextFormField.initialValue 避免每次重建新建 TextEditingController。
    return TextFormField(
      initialValue: e.textAnswer,
      onChanged: (v) => e.textAnswer = v,
      decoration: const InputDecoration(
        hintText: '手动填写答案',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      maxLines: 2,
    );
  }
}

/// 列表行类型
sealed class _ListRow {
  const _ListRow();
}

/// 分组题材料题干行 (非提交项)
class _GroupRow extends _ListRow {
  final QuestionInfo parent;
  const _GroupRow(this.parent);
}

/// 可提交的题目行
class _QuestionRow extends _ListRow {
  final _QuestionEntry entry;
  const _QuestionRow(this.entry);
}

/// 答案预览面板 (手动提交双栏左侧)
///
/// 展示已获取答案的 题号/答案/解析, 支持图片/公式富文本渲染;
/// 供试题答案页"手动提交"入口在任意获取方案下边看答案边填写。
class _AnswerPreviewPane extends StatelessWidget {
  final CourseAnswerResult result;

  const _AnswerPreviewPane({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            result.courseTitle,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '已获取 ${result.successCount}/${result.totalCount} 题 · 手动填写完成后点击下方按钮提交',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          ...result.questions
              .map((q) => _PreviewQuestionCard(question: q, isChild: false)),
          if (result.questions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  '该课程未获取到答案',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 答案预览单题卡: 题号/题型徽标 + 答案 + 解析 (子题缩进展示)
class _PreviewQuestionCard extends StatelessWidget {
  final QuestionInfo question;
  final bool isChild;

  const _PreviewQuestionCard({required this.question, this.isChild = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasChildren = question.childQuestions.isNotEmpty;
    // 父题有子题时, 答案/解析在子题中展示, 父题仅展示题号/题型
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
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.dividerColor),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 题号 + 题型
          if (question.number.isNotEmpty || question.questionType.isNotEmpty)
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
                    Text(
                      question.questionType,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          // 答案
          if (!skipAnswerFields && question.answer.isNotEmpty)
            _PreviewField(
              label: '答案',
              color: Colors.green,
              child: _answerContent(theme, question.answer),
            ),
          // 解析 (HTML 渲染)
          if (!skipAnswerFields && question.analysis.isNotEmpty)
            _PreviewField(
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
            ...question.childQuestions.map((cq) => _PreviewQuestionCard(
                  question: cq,
                  isChild: true,
                )),
          ],
        ],
      ),
    );
  }

  /// 答案内容: 客观题字母序列用绿色加粗文本, 其余 (含 HTML) 走富文本渲染
  Widget _answerContent(ThemeData theme, String answer) {
    final isObjective = RegExp(r'^[A-Z](,\s*[A-Z])*$').hasMatch(answer);
    if (isObjective) {
      return Text(
        answer,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: Colors.green.shade700,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (answer.contains('<') && answer.contains('>')) {
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

/// 答案预览带标签字段行 (答案/解析)
class _PreviewField extends StatelessWidget {
  final String label;
  final Color color;
  final Widget child;

  const _PreviewField({
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
