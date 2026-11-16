/// 教师版试卷 PDF 预览页，pdfrx 内嵌渲染、多试卷 TAB 切换，支持页码/缩放控制与本地/浏览器导出。
/// 教师版 PDF 无法自动回填，提交（做题痕迹/答题结果）统一走 ManualSubmitOrchestrator 手动填写。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/utils/web_file_saver.dart';
import '../../../download/presentation/services/download_service.dart';
import '../../domain/services/answer_submit_service.dart';
import '../services/manual_submit_helper.dart';
import '../widgets/pdfrx_viewer.dart';

/// 教师版试卷 PDF 预览页
///
/// 使用 pdfrx 内嵌渲染 PDF (禁止跳转外部阅读器/浏览器):
/// - 多张试卷以 TAB 切换 (对齐其他获取方案的 Tab 体验);
/// - 底部控制栏支持页码导航、缩放; 加载/错误态内嵌处理 (错误可重试)。
///
/// 右上角菜单 (与其他获取方案一致):
/// - 提交 (做题痕迹/答题结果): 教师版 PDF 无法自动回填, 均手动填写
///   (可选选择题、可传图片, 单题多张), 复用 [ManualSubmitOrchestrator];
/// - 导出: 已下载的教师版 PDF 保存本地 (native) / 浏览器下载 (web)。
class AnswerPdfPreviewPage extends StatefulWidget {
  /// PDF 项列表 (title → bytes + 课程答案结果),
  /// 来自 DownloadService.downloadAnswerPreviews
  final List<AnswerPreviewItem> items;

  const AnswerPdfPreviewPage({super.key, required this.items});

  /// 打开预览页
  static Future<void> push(
    BuildContext context, {
    required List<AnswerPreviewItem> items,
  }) {
    // 使用根导航打开, 覆盖侧滑栏壳层, 实现独立全屏新页面
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => AnswerPdfPreviewPage(items: items),
      ),
    );
  }

  @override
  State<AnswerPdfPreviewPage> createState() => _AnswerPdfPreviewPageState();
}

class _AnswerPdfPreviewPageState extends State<AnswerPdfPreviewPage>
    with TickerProviderStateMixin {
  late final TabController _tabController;

  /// 当前选中的 PDF 索引 (TAB 切换)
  int _tabIndex = 0;

  /// 是否正在导出 (导出按钮显示加载态)
  bool _exporting = false;

  /// 是否处于"选择课程"模式 (勾选要提交/导出的课程)
  bool _selecting = false;

  /// 已勾选的课程索引
  final Set<int> _selected = {};

  String _extension(int index) =>
      '${_sanitizeFilename(widget.items[index].title)}.pdf';

  String _sanitizeFilename(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final trimmed = cleaned.replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
    return trimmed.isEmpty ? '未命名' : trimmed;
  }

  void _toast(String msg, {bool success = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: success ? 3 : 5),
        backgroundColor:
            success ? Colors.green.shade700 : Colors.red.shade700,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: widget.items.length,
      vsync: this,
    );
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        setState(() => _tabIndex = _tabController.index);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// 提交/导出目标: 选择模式下有勾选 → 勾选项; 否则全部课程
  List<AnswerPreviewItem> _targetItems() {
    if (_selecting && _selected.isNotEmpty) {
      final idx = _selected.toList()..sort();
      return [for (final i in idx) widget.items[i]];
    }
    return widget.items;
  }

  // ─── 提交 (手动填写, 复用"提交试卷"提交逻辑) ───

  void _onSubmitSelected(String value) {
    switch (value) {
      case 'trace':
        _runManualSubmit(SubmitType.trace);
      case 'result':
        _runManualSubmit(SubmitType.result);
    }
  }

  /// 手动提交流程 (复用 [ManualSubmitOrchestrator])
  ///
  /// [explicitTargets] 非空时 (单个试卷右键/长按菜单), 只提交指定课程;
  /// 否则提交所选/全部课程 ([_targetItems])。
  Future<void> _runManualSubmit(
    SubmitType type, [
    List<AnswerPreviewItem>? explicitTargets,
  ]) async {
    final targets = explicitTargets ?? _targetItems();
    if (targets.isEmpty) {
      _toast('请先勾选要提交的课程', success: false);
      return;
    }

    // 每个课程的答案 PDF 字节 (按 paperId 关联, 供填写页双栏预览)
    final pdfByPaperId = <String, Uint8List>{
      for (final t in targets) t.result.paperId: t.bytes,
    };

    final result = await ManualSubmitOrchestrator.run(
      context: context,
      results: [for (final t in targets) t.result],
      type: type,
      pdfByPaperId: pdfByPaperId,
    );

    if (!mounted) return;
    if (result.cancelled) return; // 用户中途取消, 不提示
    final typeLabel = type == SubmitType.trace ? '做题痕迹' : '答题结果';
    if (result.fail == 0) {
      _toast('下载方案: 全部 ${result.ok} 个课程提交$typeLabel成功');
    } else {
      _toast(
        '下载方案: 完成 (成功 ${result.ok}, 失败 ${result.fail})',
        success: false,
      );
    }
  }

  // ─── 导出 ───

  void _onExportSelected(String value) {
    switch (value) {
      case 'all':
        _savePdfs(widget.items);
      case 'selected':
        _savePdfs(_targetItems());
    }
  }

  /// 将内存中的教师版 PDF 字节保存为本地文件
  ///
  /// - Native: 写入 下载目录/EwtAutoClient/试题答案/
  /// - Web: 通过 [WebFileSaver] 触发浏览器下载
  Future<void> _savePdfs(List<AnswerPreviewItem> items) async {
    if (items.isEmpty) {
      _toast('请先勾选要导出的课程', success: false);
      return;
    }
    setState(() => _exporting = true);
    try {
      if (kIsWeb) {
        for (final item in items) {
          await WebFileSaver.saveBytes(
              '${_sanitizeFilename(item.title)}.pdf', item.bytes);
        }
        _toast('已触发 ${items.length} 个 PDF 下载');
      } else {
        final dir = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        final saveDir = Directory('${dir.path}/EwtAutoClient/试题答案');
        if (!saveDir.existsSync()) saveDir.createSync(recursive: true);
        int success = 0;
        for (final item in items) {
          final filepath =
              '${saveDir.path}/${_sanitizeFilename(item.title)}.pdf';
          try {
            await File(filepath).writeAsBytes(item.bytes);
            success++;
          } catch (e) {
            debugPrint('导出失败 $filepath: $e');
          }
        }
        _toast('已导出 $success/${items.length} 个文件至 ${saveDir.path}');
      }
    } catch (e) {
      _toast('导出失败: $e', success: false);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final multi = widget.items.length > 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting
            ? '选择课程 (已选 ${_selected.length}/${widget.items.length})'
            : '试卷预览 (${widget.items.length})'),
        bottom: multi
            ? TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: [
                  for (final item in widget.items)
                    Tab(text: item.title),
                ],
              )
            : null,
        actions: [
          // 选择模式开关
          IconButton(
            icon: Icon(_selecting
                ? Icons.check_box_outlined
                : Icons.checklist_rtl),
            tooltip: _selecting ? '完成选择' : '选择课程',
            onPressed: () => setState(() => _selecting = !_selecting),
          ),
          // 选择模式下: 全选/全不选
          if (_selecting)
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: '全选/全不选',
              onPressed: () => setState(() {
                if (_selected.length == widget.items.length) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(List.generate(widget.items.length, (i) => i));
                }
              }),
            ),
          // 提交菜单 (手动填写, 复用"提交试卷")
          PopupMenuButton<String>(
            icon: const Icon(Icons.upload_outlined),
            tooltip: '提交',
            onSelected: _onSubmitSelected,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'trace', child: Text('提交做题痕迹')),
              PopupMenuItem(value: 'result', child: Text('提交答题结果')),
            ],
          ),
          // 导出菜单 (保存教师版 PDF)
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
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'all', child: Text('导出全部课程')),
              if (_selecting)
                PopupMenuItem(value: 'selected', child: Text('导出所选课程')),
            ],
          ),
        ],
      ),
      body: widget.items.isEmpty
          ? const Center(child: Text('没有可预览的试卷'))
          : Column(
              children: [
                if (multi)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Text(
                      widget.items[_tabIndex].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                Expanded(
                  child: PdfrxViewer(
                    bytes: widget.items[_tabIndex].bytes,
                    sourceName: _extension(_tabIndex),
                  ),
                ),
              ],
            ),
    );
  }
}
