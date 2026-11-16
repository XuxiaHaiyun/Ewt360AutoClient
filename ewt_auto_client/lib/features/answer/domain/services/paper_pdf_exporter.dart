/// 试题 PDF 导出工具，基于 pdf 包把课程试题/答案渲染为 PDF 文件，支持中文字体与字段级导出配置。
/// 仅 native 平台可用（依赖 dart:io）；Web 平台改用 exportBatchToBytes 配合 WebFileSaver。
library;

import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../core/network/api_helper.dart';
import '../../domain/entities/export_font_config.dart';
import '../../domain/entities/question_info.dart';

/// 试题 PDF 导出工具
///
/// 对应 Python: gui/dialogs/answer.py build_pdf_document + export_pdf_to_file
/// 以及 tasks/course_download.py _export_paper_pdf
///
/// 使用 pdf 包生成 PDF, 支持中文字体 (从系统加载 CJK 字体).
/// 导出字段对齐 Python _download_paper: question_content + options (不含答案/解析/知识点)
/// 也支持完整模式 (含答案/解析/知识点) 用于"试题答案"导出.
class PaperPdfExporter {
  PaperPdfExporter._();

  /// 模块级调试日志出口 (统一收敛 debugPrint, 后续接入全局日志器时仅改此处)
  static void _debugLog(String message) {
    // ignore: avoid_print
    debugPrint(message);
  }

  /// 导出单个课程试题为 PDF
  ///
  /// [result] 课程答案结果
  /// [filepath] 输出文件路径 (.pdf)
  /// [includeAnswer] 是否包含答案/解析/知识点 (false=仅试题, 对齐 Python _download_paper)
  /// [docTitle] 文档标题 (null=不显示标题)
  /// [showSuccess] 是否显示"成功 X/Y"统计
  /// [fontConfig] PDF 字体配置 (默认内置 HarmonyOS Sans SC)
  static Future<bool> export(
    CourseAnswerResult result,
    String filepath, {
    bool includeAnswer = false,
    String? docTitle,
    bool showSuccess = false,
    AnswerExportFields fields = AnswerExportFields.all,
    ExportFontConfig fontConfig = const ExportFontConfig(),
  }) async {
    return exportBatch(
      [result],
      filepath,
      includeAnswer: includeAnswer,
      docTitle: docTitle,
      showSuccess: showSuccess,
      fields: fields,
      fontConfig: fontConfig,
    );
  }

  /// 批量导出多课程答案到单个 PDF (对齐 Python build_pdf_document)
  ///
  /// [results] 多个课程的答案结果列表
  /// [filepath] 输出文件路径 (.pdf)
  /// [includeAnswer] 是否包含答案/解析/知识点
  /// [docTitle] 文档标题 (null=不显示标题)
  /// [showSuccess] 是否显示"成功 X/Y"统计
  /// [fields] 字段级导出配置 (控制原题/选项/答案/知识点/难度/解析)
  /// [fontConfig] PDF 字体配置 (默认内置 HarmonyOS Sans SC)
  ///
  /// 对齐 Python: gui/workers/batch_operation.py _do_answers 中
  ///   answers_data = [course_answers, ...] → build_pdf_document(fields, answers_data)
  /// 多课程题目合并到一个 PDF, 每课程前显示课程标题分隔.
  ///
  /// 注意: 此方法依赖 dart:io File, 仅 native 平台可用。Web 平台请用 [exportBatchToBytes] + WebFileSaver。
  static Future<bool> exportBatch(
    List<CourseAnswerResult> results,
    String filepath, {
    bool includeAnswer = false,
    String? docTitle,
    bool showSuccess = false,
    AnswerExportFields fields = AnswerExportFields.all,
    ExportFontConfig fontConfig = const ExportFontConfig(),
  }) async {
    final bytes = await exportBatchToBytes(
      results,
      includeAnswer: includeAnswer,
      docTitle: docTitle,
      showSuccess: showSuccess,
      fields: fields,
      fontConfig: fontConfig,
    );
    if (bytes == null) return false;
    try {
      final file = File(filepath);
      final dir = file.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await file.writeAsBytes(bytes);
      return true;
    } catch (e, st) {
      _debugLog('PaperPdfExporter.exportBatch 写文件失败: $e');
      _debugLog('$st');
      return false;
    }
  }

  /// 批量导出多课程答案到 PDF 字节序列 (内存版, 跨平台)
  ///
  /// 与 [exportBatch] 等价但不写文件, 返回 PDF 字节序列。
  /// Web 平台调用方应配合 [WebFileSaver] 触发浏览器下载。
  ///
  /// 返回 null 表示生成失败 (错误已通过 debugPrint 输出)。
  static Future<Uint8List?> exportBatchToBytes(
    List<CourseAnswerResult> results, {
    bool includeAnswer = false,
    String? docTitle,
    bool showSuccess = false,
    AnswerExportFields fields = AnswerExportFields.all,
    ExportFontConfig fontConfig = const ExportFontConfig(),
  }) async {
    try {
      final (baseFont, boldFont) = await _loadFontFromConfig(fontConfig);
      // 注意: pdf 3.13.0 中 Text.canSpan 只读 widget 自身 overflow 字段
      // (text.dart:1363), theme.overflow 不参与 canSpan 判断. 因此跨页拆分
      // 必须在具体的长文本 Text/RichText 上显式传 overflow: TextOverflow.span,
      // 见 _buildRichContent / 知识点渲染处.
      final theme = pw.ThemeData.withFont(
        base: baseFont,
        bold: boldFont,
      );

      final pdf = pw.Document(theme: theme);

      // 预取所有图片/公式 (SVG + 位图), 供 PDF 内嵌渲染
      final cdnHeaders = _ewtCdnHeaders();
      final imageCache = await _prefetchImages(_collectImgSrcs(results), cdnHeaders);

      // 汇总统计
      final totalQuestions =
          results.fold(0, (a, r) => a + r.successCount);
      final totalAll =
          results.fold(0, (a, r) => a + r.totalCount);

      // 构建 widgets: 多课程题目合并到一个 MultiPage
      final widgets = <pw.Widget>[];

      for (int i = 0; i < results.length; i++) {
        final result = results[i];

        // 课程间分隔 (第一课程前不加)
        if (i > 0) {
          widgets.add(pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 8),
            child: pw.Divider(thickness: 1, color: PdfColors.grey300),
          ));
        }

        // 课程信息卡 (对齐界面顶部信息卡)
        widgets.add(_buildCourseHeader(result, showSuccess));
        widgets.add(pw.SizedBox(height: 8));

        // 题目列表 (扁平 block, 长文本可跨页拆分)
        for (final q in result.questions) {
          widgets.addAll(_buildQuestion(q, includeAnswer, fields, imageCache,
              isChild: false));
        }
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          // 答案内容可能很长 (多课程/多题/长解析), 默认 maxPages=20 很容易触发
          // PdfTooBigPageException. 真正的"不可拆分"问题已由题目结构扁平化 +
          // RichText(overflow: span) 解决 (见 _buildQuestion 注释),
          // 这里仅兜底正常的大文档.
          maxPages: 2000,
          margin: const pw.EdgeInsets.all(40),
          header: docTitle != null
              ? (ctx) => pw.Container(
                    alignment: pw.Alignment.center,
                    padding: const pw.EdgeInsets.only(bottom: 8),
                    decoration: const pw.BoxDecoration(
                      border: pw.Border(
                        bottom: pw.BorderSide(width: 1.5),
                      ),
                    ),
                    child: pw.Text(
                      docTitle,
                      style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  )
              : null,
          footer: (ctx) => pw.Container(
            alignment: pw.Alignment.center,
            padding: const pw.EdgeInsets.only(top: 8),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                top: pw.BorderSide(width: 0.5, color: PdfColors.grey400),
              ),
            ),
            child: pw.Text(
              results.length > 1
                  ? '批量答案 $totalQuestions/$totalAll 题  -  ${ctx.pageNumber}/${ctx.pagesCount}'
                  : '${results.first.courseTitle}  -  ${ctx.pageNumber}/${ctx.pagesCount}',
              style:
                  const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
          ),
          build: (ctx) => widgets,
        ),
      );

      return await pdf.save();
    } catch (e, st) {
      _debugLog('PaperPdfExporter.exportBatchToBytes 失败: $e');
      _debugLog('$st');
      return null;
    }
  }

  /// 课程信息卡 (对齐界面顶部信息卡: 标题 + 学科/日期/方案 + 计数徽标)
  static pw.Widget _buildCourseHeader(
      CourseAnswerResult result, bool showSuccess) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.blue50,
        borderRadius: pw.BorderRadius.circular(6),
        border: pw.Border.all(color: PdfColors.blue100, width: 0.75),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            result.courseTitle,
            style: pw.TextStyle(
              fontSize: 13,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.blue800,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              if (result.subjectName.isNotEmpty)
                _metaChip('学科', result.subjectName),
              if (result.dateLabel.isNotEmpty)
                _metaChip('日期', result.dateLabel),
              if (result.method.isNotEmpty) _metaChip('方案', result.method),
              pw.Expanded(child: pw.Container()),
              _countBadge(result, showSuccess),
            ],
          ),
        ],
      ),
    );
  }

  /// 元信息小标签 (label: value, label 灰 value 深)
  static pw.Widget _metaChip(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(right: 12),
        child: pw.RichText(
          text: pw.TextSpan(
            style: const pw.TextStyle(fontSize: 8.5),
            children: [
              pw.TextSpan(
                text: '$label：',
                style: pw.TextStyle(color: PdfColors.grey500),
              ),
              pw.TextSpan(
                text: value,
                style: pw.TextStyle(
                  color: PdfColors.grey800,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );

  /// 题目计数徽标 (成功数/总数)
  static pw.Widget _countBadge(
      CourseAnswerResult result, bool showSuccess) {
    final color = showSuccess ? PdfColors.green700 : PdfColors.grey700;
    final bg = showSuccess ? PdfColors.green50 : PdfColors.grey100;
    final border = showSuccess ? PdfColors.green200 : PdfColors.grey200;
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: pw.BoxDecoration(
        color: bg,
        borderRadius: pw.BorderRadius.circular(3),
        border: pw.Border.all(color: border, width: 0.5),
      ),
      child: pw.Text(
        '${result.successCount}/${result.totalCount}',
        style: pw.TextStyle(
          fontSize: 8.5,
          fontWeight: pw.FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  /// 构建单个题目的 PDF Widget 列表 (扁平化: 每个 block 直接作为 MultiPage child)
  ///
  /// **为什么必须扁平化 (pdf 3.13.0 源码结论, 勿改回卡片 Column 结构):**
  /// - Flex/Column 的跨页拆分只能发生在它的**直接 children 边界**
  ///   (flex.dart:284 `allocatedSize > maxHeight` 即 break, restoreContext
  ///   仅推进 firstChild), 且给 child 的约束不限高 —— 它永远不会把一个
  ///   "自身超过一页高"的嵌套 child 交给该 child 去二次拆分。
  /// - 当 Column 的第一个 child 就超页高时 lastChild == firstChild 零进度,
  ///   而 Flex.hasMoreWidgets 恒为 true → MultiPage 每页零消费无限开新页
  ///   → PdfTooBigPageException。
  /// - 因此长文本 (题干/答案/解析) 的 RichText(overflow: span) 必须是
  ///   MultiPage 的直接 child, 中间只允许 Padding 等 SingleChildWidget
  ///   (canSpan 逐层委托), 不能隔任何 Column/卡片 Container。
  static List<pw.Widget> _buildQuestion(
      QuestionInfo q,
      bool includeAnswer,
      AnswerExportFields fields,
      Map<String, _ImgData?> imageCache,
      {bool isChild = false}) {
    final blocks = <pw.Widget>[];
    final indent = isChild ? 10.0 : 0.0;

    // 包一层缩进/间距 Padding (SingleChildWidget, canSpan 委托 child, 安全)
    pw.Widget block(pw.Widget w,
            {double extraLeft = 0, double top = 0, double bottom = 0}) =>
        pw.Padding(
          padding: pw.EdgeInsets.only(
              left: indent + extraLeft, top: top, bottom: bottom),
          child: w,
        );

    // 题号 + 题型 + 难度 + 分组 (短内容, Row 不可拆但高度远小于一页)
    if (q.number.isNotEmpty ||
        (fields.showQuestionType && q.questionType.isNotEmpty)) {
      blocks.add(block(
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            if (q.number.isNotEmpty) _numberBadge(q.number),
            if (fields.showQuestionType && q.questionType.isNotEmpty)
              _typeBadge(q.questionType),
            if (fields.showDifficulty && q.difficulty.isNotEmpty) ...[
              pw.SizedBox(width: 6),
              pw.Text(q.difficulty,
                  style: const pw.TextStyle(
                      fontSize: 9, color: PdfColors.grey600)),
            ],
            if (q.group.isNotEmpty) ...[
              pw.SizedBox(width: 6),
              pw.Text('[${q.group}]',
                  style: const pw.TextStyle(
                      fontSize: 9, color: PdfColors.grey500)),
            ],
          ],
        ),
        top: isChild ? 4 : 0,
        bottom: 3,
      ));
    }

    // 题干 (可能很长 → 直接 block, RichText span 可跨页)
    if (fields.showQuestionContent && q.questionContent.isNotEmpty) {
      blocks.add(block(
        _buildRichContent(q.questionContent, imageCache, fontSize: 11),
        bottom: 5,
      ));
    }

    // 选项: 每个选项独立 block (整组选项也可能合计超一页)
    if (fields.showOptions && q.options.isNotEmpty) {
      for (final opt in q.options) {
        blocks.add(block(
          _buildRichContent(opt, imageCache, fontSize: 10),
          extraLeft: 12,
          bottom: 2,
        ));
      }
    }

    // 答案 / 知识点 / 解析: 标签药丸与内容拆成两个相邻 block
    void labeled(String label, pw.Widget content, PdfColor color,
        PdfColor bg) {
      blocks.add(block(_labelPill(label, color, bg), top: 4, bottom: 2));
      blocks.add(block(content, bottom: 2));
    }

    if (includeAnswer && fields.showAnswer && q.answer.isNotEmpty) {
      labeled('答案', _buildRichContent(q.answer, imageCache, fontSize: 10),
          PdfColors.green700, PdfColors.green50);
    }
    if (includeAnswer && fields.showKnowledge && q.knowledge.isNotEmpty) {
      labeled(
          '知识点',
          pw.Text(_stripHtml(q.knowledge),
              style: const pw.TextStyle(fontSize: 10, lineSpacing: 1.4),
              overflow: pw.TextOverflow.span),
          PdfColors.purple700,
          PdfColors.purple50);
    }
    if (includeAnswer && fields.showAnalysis && q.analysis.isNotEmpty) {
      labeled('解析', _buildRichContent(q.analysis, imageCache, fontSize: 10),
          PdfColors.orange800, PdfColors.orange50);
    }

    // 子题: 递归扁平化, 以缩进区分 (不再用左边框容器包 Column)
    for (final child in q.childQuestions) {
      blocks.addAll(_buildQuestion(child, includeAnswer, fields, imageCache,
          isChild: true));
    }

    // 题目间分隔线 (仅父题)
    if (!isChild) {
      blocks.add(pw.Padding(
        padding: const pw.EdgeInsets.only(top: 6, bottom: 6),
        child: pw.Divider(
            thickness: 0.75, height: 0.75, color: PdfColors.grey300),
      ));
    }

    return blocks;
  }

  /// 题号徽标 (对齐界面 secondaryContainer 风格)
  static pw.Widget _numberBadge(String number) => pw.Container(
        margin: const pw.EdgeInsets.only(right: 6),
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: pw.BoxDecoration(
          color: PdfColors.blue100,
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Text(
          number,
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.blue800,
          ),
        ),
      );

  /// 题型徽标 (对齐界面 primaryContainer 风格)
  static pw.Widget _typeBadge(String type) => pw.Container(
        margin: const pw.EdgeInsets.only(right: 4),
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: pw.BoxDecoration(
          color: PdfColors.blue50,
          borderRadius: pw.BorderRadius.circular(3),
          border: pw.Border.all(color: PdfColors.blue100, width: 0.5),
        ),
        child: pw.Text(
          type,
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.blue800),
        ),
      );

  /// 带彩色标签的字段行 (答案/知识点/解析, 对齐界面 _LabeledField)
  ///
  /// 注意: 不能用 pw.Row + pw.Expanded 包裹长文本 —— Row 是横向布局、无法纵向分页,
  /// 字段标签药丸 (答案/知识点/解析)。
  ///
  /// 注意: 标签与内容必须是两个**相邻的 MultiPage 直接 block**
  /// (见 _buildQuestion 的 labeled()), 不能用 Column 包起来 ——
  /// Flex 不会把超页高的嵌套 child 交给 child 自己拆分, 会导致
  /// PdfTooBigPageException 无限开新页。
  static pw.Widget _labelPill(String label, PdfColor color, PdfColor bg) =>
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: pw.BoxDecoration(
          color: bg,
          borderRadius: pw.BorderRadius.circular(3),
          border: pw.Border.all(color: color, width: 0.5),
        ),
        child: pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
            color: color,
          ),
        ),
      );

  /// 按字体配置加载字体, 返回 (base, bold)
  ///
  /// 优先级:
  /// 1. [ExportFontType.bundled] - 从 assets 加载内置鸿蒙字体 (默认, 跨平台稳定)
  /// 2. [ExportFontType.custom] - 从用户选择的 TTF 文件路径加载
  /// 3. [ExportFontType.system] - 从系统字体目录加载 (Windows/Android/Linux/macOS)
  ///
  /// 任何字体加载失败时回退到内置鸿蒙字体, 再失败回退 Helvetica。
  static Future<(pw.Font, pw.Font)> _loadFontFromConfig(
      ExportFontConfig config) async {
    try {
      switch (config.type) {
        case ExportFontType.bundled:
          return await _loadBundledFont(config.bundledName);

        case ExportFontType.custom:
          if (config.customFontPath.isEmpty) {
            _debugLog('PaperPdfExporter: 自定义字体路径为空, 回退内置字体');
            return await _loadBundledFont('harmonyos');
          }
          return await _loadCustomFont(config.customFontPath);

        case ExportFontType.system:
          return await _loadSystemFont();
      }
    } catch (e) {
      _debugLog('PaperPdfExporter: 字体加载失败($config), 回退内置: $e');
      try {
        return await _loadBundledFont('harmonyos');
      } catch (_) {
        final font = pw.Font.helvetica();
        return (font, font);
      }
    }
  }

  /// 加载内置字体 (从 assets)
  ///
  /// 内置字体已随 APP 打包, 跨平台稳定, 不依赖系统字体。
  static Future<(pw.Font, pw.Font)> _loadBundledFont(String name) async {
    final option = BundledFontOption.all.firstWhere(
      (o) => o.name == name,
      orElse: () => BundledFontOption.harmonyos,
    );

    final baseData = await rootBundle.load(option.assetPath);
    final baseFont = pw.Font.ttf(baseData);

    pw.Font boldFont = baseFont;
    if (option.boldAssetPath != null) {
      try {
        final boldData = await rootBundle.load(option.boldAssetPath!);
        boldFont = pw.Font.ttf(boldData);
      } catch (e) {
        _debugLog('PaperPdfExporter: 粗体加载失败, 使用常规体: $e');
      }
    }

    _debugLog('PaperPdfExporter: 加载内置字体 ${option.label}');
    return (baseFont, boldFont);
  }

  /// 加载自定义 TTF 文件
  static Future<(pw.Font, pw.Font)> _loadCustomFont(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('字体文件不存在: $path');
    }
    final bytes = await file.readAsBytes();
    final byteData =
        bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);
    final font = pw.Font.ttf(byteData);
    _debugLog('PaperPdfExporter: 加载自定义字体 $path (${bytes.length} bytes)');
    return (font, font); // 自定义字体只有常规体, 粗体复用
  }

  /// 加载系统字体 (跨平台)
  ///
  /// 仅加载 TTF/OTF 格式字体, 跳过 TTC (TrueType Collection):
  /// pdf 包的 Font.ttf 对 TTC 文件解析不稳定, 可能不抛异常但产生
  /// 不完整的字体对象, 导致后续 PDF 生成时崩溃 (中文渲染失败)。
  ///
  /// 平台字体路径:
  /// - Windows: C:/Windows/Fonts/ (msyh.ttf / Deng.ttf / simhei.ttf)
  /// - Android: /system/fonts/ (NotoSansSC.otf / DroidSansFallback.ttf)
  /// - Linux:   /usr/share/fonts/ (wqy-microhei.ttc → 跳过, 用 OTF)
  /// - macOS:   /System/Library/Fonts/ (PingFang.ttc → 跳过, 用 STHeiti.ttf)
  /// - Web:     无法访问系统字体, 回退内置字体
  static Future<(pw.Font, pw.Font)> _loadSystemFont() async {
    if (kIsWeb) {
      _debugLog('PaperPdfExporter: Web 平台无系统字体, 回退内置字体');
      return await _loadBundledFont('harmonyos');
    }

    // 仅 TTF/OTF 候选 (TTC 文件会导致 pdf 包解析异常或产生坏字体,
    // 详见: https://github.com/DavBfr/dart_pdf/issues/iami)
    final candidates = <String>[
      // Windows TTF (微软雅黑/等线/黑体/楷体)
      'C:/Windows/Fonts/msyh.ttf',
      'C:/Windows/Fonts/msyhbd.ttf',
      'C:/Windows/Fonts/simhei.ttf',
      'C:/Windows/Fonts/simkai.ttf',
      'C:/Windows/Fonts/Deng.ttf',
      // Android OTF/TTF (NotoSansSC / DroidSansFallback)
      '/system/fonts/NotoSansSC-Regular.otf',
      '/system/fonts/NotoSansSC-Bold.otf',
      '/system/fonts/DroidSansFallback.ttf',
      '/system/fonts/DroidSansFallbackFull.ttf',
      // Linux TTF (wqy-microhei 有 TTF 版本)
      '/usr/share/fonts/truetype/wqy/wqy-microhei.ttf',
      '/usr/share/fonts/wqy-microhei/wqy-microhei.ttf',
      // macOS TTF (Arial Unicode 是 TTF 格式, 包含 CJK)
      '/Library/Fonts/Arial Unicode.ttf',
      '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
    ];

    String? lastError;
    for (final path in candidates) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          // 使用 ByteData.sublistView (比 buffer.asByteData 更安全)
          final byteData = ByteData.sublistView(bytes);
          final font = pw.Font.ttf(byteData);
          _debugLog('PaperPdfExporter: 加载系统字体成功 $path (${bytes.length} bytes)');
          return (font, font);
        }
      } catch (e) {
        lastError = '$path: $e';
        _debugLog('PaperPdfExporter: 系统字体加载失败 $path: $e');
        continue;
      }
    }

    _debugLog('PaperPdfExporter: 所有系统字体加载失败, 回退内置字体. 最后错误: $lastError');
    return await _loadBundledFont('harmonyos');
  }

  /// 去 HTML 标签, 保留纯文本 (完整 HTML 实体解码)
  ///
  /// 支持常见命名实体 (&times; &ldquo; &rdquo; &hellip; 等) 和数字实体 (&#8217;).
  static String _stripHtml(String html) {
    var result = html
        // 公式图片 → [公式], 普通图片 → [图片]
        .replaceAllMapped(
            RegExp(r'<img[^>]*alt="\[公式\]"[^>]*>'), (_) => '[公式]')
        .replaceAllMapped(
            RegExp(r'<img[^>]*Wirisformula[^>]*>'), (_) => '[公式]')
        .replaceAllMapped(
            RegExp(r'''<img[^>]*data-type=["']?mathType["']?[^>]*>'''),
            (_) => '[公式]')
        .replaceAll(RegExp(r'<img[^>]*>'), '[图片]')
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</p>|</div>|</li>|</h[1-6]>|</tr>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    // 解码 HTML 实体 (命名 + 数字)
    result = _decodeHtmlEntities(result);
    // 规范化空白
    result = result
        .replaceAll('\u00a0', ' ') // &nbsp; → 普通空格
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return result;
  }

  /// 解码 HTML 实体 (命名实体 + 数字实体)
  static String _decodeHtmlEntities(String text) {
    // 常见命名实体
    const namedEntities = <String, String>{
      '&nbsp;': ' ',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&apos;': "'",
      '&amp;': '&',
      '&times;': '×',
      '&divide;': '÷',
      '&ldquo;': '\u201C',
      '&rdquo;': '\u201D',
      '&lsquo;': '\u2018',
      '&rsquo;': '\u2019',
      '&hellip;': '…',
      '&mdash;': '—',
      '&ndash;': '–',
      '&deg;': '°',
      '&plusmn;': '±',
      '&le;': '≤',
      '&ge;': '≥',
      '&ne;': '≠',
      '&approx;': '≈',
      '&infin;': '∞',
      '&sum;': '∑',
      '&prod;': '∏',
      '&int;': '∫',
      '&radic;': '√',
      '&alpha;': 'α',
      '&beta;': 'β',
      '&gamma;': 'γ',
      '&delta;': 'δ',
      '&epsilon;': 'ε',
      '&pi;': 'π',
      '&theta;': 'θ',
      '&lambda;': 'λ',
      '&mu;': 'μ',
      '&sigma;': 'σ',
      '&omega;': 'ω',
      '&Alpha;': 'Α',
      '&Beta;': 'Β',
      '&Gamma;': 'Γ',
      '&Delta;': 'Δ',
      '&Sigma;': 'Σ',
      '&Omega;': 'Ω',
      '&sub;': '⊂',
      '&sup;': '⊃',
      '&isin;': '∈',
      '&notin;': '∉',
      '&cap;': '∩',
      '&cup;': '∪',
      '&forall;': '∀',
      '&exist;': '∃',
      '&rarr;': '→',
      '&larr;': '←',
      '&harr;': '↔',
      '&uarr;': '↑',
      '&darr;': '↓',
      '&hArr;': '⇔',
      '&rArr;': '⇒',
      '&copy;': '©',
      '&reg;': '®',
      '&trade;': '™',
      '&sect;': '§',
      '&para;': '¶',
      '&middot;': '·',
      '&bull;': '•',
      '&dagger;': '†',
      '&Dagger;': '‡',
      '&permil;': '‰',
      '&prime;': '′',
      '&Prime;': '″',
      '&frac12;': '½',
      '&frac14;': '¼',
      '&frac34;': '¾',
      '&sup1;': '¹',
      '&sup2;': '²',
      '&sup3;': '³',
    };
    var result = text;
    for (final entry in namedEntities.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    // 数字实体 &#NNN; / &#xHHH;
    result = result.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) => String.fromCharCode(int.tryParse(m.group(1) ?? '') ?? 0),
    );
    result = result.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (m) => String.fromCharCode(
          int.tryParse(m.group(1) ?? '', radix: 16) ?? 0),
    );
    return result;
  }

  // ─────────────────────────────────────────────────────────────
  // 图片 / 公式内嵌支持 (供 PDF 渲染, 对齐显示端的 EWT CDN 图片)
  // ─────────────────────────────────────────────────────────────

  /// EWT CDN 图片请求头 (对齐显示端 HAR: web.ewt360.com)
  static Map<String, String> _ewtCdnHeaders() => {
        ...ApiHeaders.web,
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36',
        'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
      };

  /// 规整图片 URL (与显示端一致的 https 兜底)
  static String _normalizeUrl(String src) {
    var s = src.trim();
    if (s.startsWith('//')) {
      s = 'https:$s';
    } else if (s.startsWith('http://')) {
      s = 'https://${s.substring(7)}';
    }
    return s;
  }

  /// 收集所有题目字段中的 <img src>, 去重
  static List<String> _collectImgSrcs(List<CourseAnswerResult> results) {
    final urls = <String>[];
    final reg = RegExp(r'<img\b[^>]*\bsrc\s*=\s*([^\s>]+)');
    void scan(String? html) {
      if (html == null || html.isEmpty) return;
      for (final m in reg.allMatches(html)) {
        var s = m.group(1)!;
        if (s.length >= 2 &&
            ((s.startsWith('"') && s.endsWith('"')) ||
                (s.startsWith("'") && s.endsWith("'")))) {
          s = s.substring(1, s.length - 1);
        }
        urls.add(_normalizeUrl(s));
      }
    }

    void scanQ(QuestionInfo q) {
      scan(q.questionContent);
      for (final o in q.options) {
        scan(o);
      }
      scan(q.answer);
      scan(q.analysis);
      for (final c in q.childQuestions) {
        scanQ(c);
      }
    }

    for (final r in results) {
      for (final q in r.questions) {
        scanQ(q);
      }
    }
    final seen = <String>{};
    return urls.where((u) => seen.add(u)).toList();
  }

  /// 预取所有图片字节 (SVG / 位图), 失败记为 null (导出时显示占位)
  static Future<Map<String, _ImgData?>> _prefetchImages(
    List<String> urls,
    Map<String, String> headers,
  ) async {
    final map = <String, _ImgData?>{};
    if (urls.isEmpty) return map;
    await Future.wait(urls.map((url) async {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url));
        headers.forEach((k, v) => req.headers.set(k, v));
        final resp =
            await req.close().timeout(const Duration(seconds: 15));
        if (resp.statusCode != 200) {
          map[url] = null;
          return;
        }
        final bytes = await consolidateHttpClientResponseBytes(resp);
        if (bytes.isEmpty) {
          map[url] = null;
          return;
        }
        final ct = resp.headers.contentType?.mimeType.toLowerCase() ?? '';
        final isSvg = url.toLowerCase().endsWith('.svg') ||
            ct.contains('svg') ||
            _looksLikeSvg(bytes);
        map[url] = _ImgData(bytes, isSvg);
      } catch (e) {
        _debugLog('PaperPdfExporter: 图片预取失败 $url: $e');
        map[url] = null;
      } finally {
        client.close();
      }
    }));
    return map;
  }

  /// 通过字节前缀粗略判断是否为 SVG
  static bool _looksLikeSvg(Uint8List b) {
    if (b.length < 4) return false;
    final head =
        String.fromCharCodes(b.sublist(0, b.length > 256 ? 256 : b.length));
    final trimmed = head.trimLeft().toLowerCase();
    return trimmed.startsWith('<?xml') || trimmed.startsWith('<svg');
  }

  /// 解析 SVG 宽高比 (w/h), 默认 1.0
  static double _svgAspect(String svg) {
    final vb = RegExp(r'viewBox[^>]*([\d.]+)\s+([\d.]+)').firstMatch(svg);
    if (vb != null) {
      final w = double.tryParse(vb.group(1)!);
      final h = double.tryParse(vb.group(2)!);
      if (w != null && h != null && h > 0) return w / h;
    }
    final wh = RegExp(r'\bwidth\s*=\s*[^>\s]*?([\d.]+)').firstMatch(svg);
    final ht = RegExp(r'\bheight\s*=\s*[^>\s]*?([\d.]+)').firstMatch(svg);
    if (wh != null && ht != null) {
      final w = double.tryParse(wh.group(1)!);
      final h = double.tryParse(ht.group(1)!);
      if (w != null && h != null && h > 0) return w / h;
    }
    return 1.0;
  }

  /// 解析位图 (PNG / JPEG / GIF / WebP) 的真实像素尺寸, 失败返回 null.
  ///
  /// 关键: `pw.MemoryImage` 在 widget 构建期尚未解码, 其 `width/height` 为 0.
  /// 若不自行解析, 位图会被当作 1:1 压成约 14pt 的方块, 看起来"不显示",
  /// 且不同比例的图片被压成各种形状 → "大小不一". 这里解析真实宽高比来解决.
  static (int, int)? _rasterSize(Uint8List b) {
    if (b.length < 16) return null;

    // PNG: 89 50 4E 47 0D 0A 1A 0A; IHDR 中 width@16 / height@20 (大端)
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return (w, h);
    }

    // GIF: "GIF87a" / "GIF89a"; width@6 / height@8 (小端)
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      final w = b[6] | (b[7] << 8);
      final h = b[8] | (b[9] << 8);
      return (w, h);
    }

    // JPEG: FF D8 ... 找第一个 SOF 段 (C0–CF, 排除 C4/C8/CC)
    if (b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) break;
        final marker = b[i + 1];
        if (marker >= 0xC0 && marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          return (w, h);
        }
        final len = (b[i + 2] << 8) | b[i + 3];
        if (len <= 0) break;
        i += 2 + len;
      }
    }

    // WebP: RIFF....WEBP + VP8 / VP8L / VP8X
    if (b.length > 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      final fourcc = String.fromCharCodes(b.sublist(12, 16));
      if (fourcc == 'VP8X' && b.length >= 30) {
        final w = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
        final h = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
        return (w, h);
      }
      if (fourcc == 'VP8 ' && b.length >= 26) {
        final w = ((b[20] | (b[21] << 8)) & 0x3FFF) + 1;
        final h = ((b[22] | (b[23] << 8)) & 0x3FFF) + 1;
        return (w, h);
      }
      if (fourcc == 'VP8L' && b.length >= 25) {
        final w = ((b[21] | (b[22] << 8)) & 0x3FFF) + 1;
        final h = (((b[22] >> 4) | (b[23] << 4) | (b[24] << 12)) & 0x3FFF) + 1;
        return (w, h);
      }
    }
    return null;
  }

  /// 将单个图片字节转换为可内联的 WidgetSpan (公式用 SVG, 位图用 Image)
  static pw.InlineSpan _imageSpan(_ImgData data, double fontSize) {
    const targetH = 14.0;
    const maxW = 460.0;
    if (data.isSvg) {
      final svgStr = utf8.decode(data.bytes, allowMalformed: true);
      final aspect = _svgAspect(svgStr);
      var w = targetH * aspect;
      var h = targetH;
      if (w > maxW) {
        w = maxW;
        h = maxW / aspect;
      }
      try {
        return pw.WidgetSpan(
          child: pw.SizedBox(
            width: w,
            height: h,
            child: pw.SvgImage(
              svg: svgStr,
              width: w,
              height: h,
              fit: pw.BoxFit.contain,
            ),
          ),
        );
      } catch (e) {
        _debugLog('PaperPdfExporter: SVG 渲染失败: $e');
        return pw.TextSpan(
          text: '[公式]',
          style: pw.TextStyle(fontSize: fontSize, color: PdfColors.orange),
        );
      }
    }
    try {
      final provider = pw.MemoryImage(data.bytes);
      // MemoryImage 构建期 width/height 为 0, 必须自行解析真实尺寸, 否则 1:1.
      final size = _rasterSize(data.bytes);
      double w;
      double h;
      if (size != null && size.$1 > 0 && size.$2 > 0) {
        // 按真实比例渲染: 仅缩小不放大, 上限 宽 400 / 高 180, 保证可读且不过分撑大行高.
        w = size.$1.toDouble();
        h = size.$2.toDouble();
        const capW = 400.0;
        const capH = 180.0;
        final scale =
            [capW / w, capH / h, 1.0].reduce((a, b) => a < b ? a : b);
        w *= scale;
        h *= scale;
      } else {
        // 解析失败: 退化为较小内联尺寸, 至少可见, 不撑破排版.
        w = 14.0;
        h = 14.0;
      }
      return pw.WidgetSpan(
        child: pw.SizedBox(
          width: w,
          height: h,
          child: pw.Image(provider, width: w, height: h, fit: pw.BoxFit.contain),
        ),
      );
    } catch (e) {
      _debugLog('PaperPdfExporter: 位图渲染失败: $e');
      return pw.TextSpan(
        text: '[图片]',
        style: pw.TextStyle(fontSize: fontSize, color: PdfColors.orange),
      );
    }
  }

  /// 将含 <img> 的 HTML 渲染为 (文本 + 内联图片) 富文本, 支持公式与图片
  static pw.Widget _buildRichContent(
    String html,
    Map<String, _ImgData?> cache, {
    double fontSize = 11,
  }) {
    // 无图片: 走原有纯文本路径, 保持行为一致
    if (!html.contains('<img')) {
      return pw.Text(
        _stripHtml(html),
        style: pw.TextStyle(fontSize: fontSize, lineSpacing: 1.4),
        // canSpan 只看 widget 自身 overflow 字段, 必须显式指定 span
        // 才能让超过一页的长文本跨页拆分, 否则 MultiPage 无限开新页
        overflow: pw.TextOverflow.span,
      );
    }
    final imgReg = RegExp(r'<img\b[^>]*>');
    final spans = <pw.InlineSpan>[];
    int last = 0;
    for (final m in imgReg.allMatches(html)) {
      final textBefore = html.substring(last, m.start);
      final cleaned = _stripHtml(textBefore);
      if (cleaned.isNotEmpty) {
        spans.add(pw.TextSpan(
          text: cleaned,
          style: pw.TextStyle(fontSize: fontSize, lineSpacing: 1.4),
        ));
      }
      final tag = m.group(0)!;
      final srcM = RegExp(r'src\s*=\s*([^\s>]+)').firstMatch(tag);
      if (srcM != null) {
        var raw = srcM.group(1)!;
        if (raw.length >= 2 &&
            ((raw.startsWith('"') && raw.endsWith('"')) ||
                (raw.startsWith("'") && raw.endsWith("'")))) {
          raw = raw.substring(1, raw.length - 1);
        }
        final src = _normalizeUrl(raw);
        final data = cache[src];
        if (data != null) {
          spans.add(_imageSpan(data, fontSize));
        } else {
          final isFormula =
              tag.contains('Wirisformula') || tag.contains('公式');
          spans.add(pw.TextSpan(
            text: isFormula ? '[公式]' : '[图片]',
            style: pw.TextStyle(fontSize: fontSize, color: PdfColors.orange),
          ));
        }
      }
      last = m.end;
    }
    final tail = html.substring(last);
    final tailClean = _stripHtml(tail);
    if (tailClean.isNotEmpty) {
      spans.add(pw.TextSpan(
        text: tailClean,
        style: pw.TextStyle(fontSize: fontSize, lineSpacing: 1.4),
      ));
    }
    if (spans.isEmpty) {
      return pw.Text(
        _stripHtml(html),
        style: pw.TextStyle(fontSize: fontSize),
        overflow: pw.TextOverflow.span,
      );
    }
    return pw.RichText(
      text: pw.TextSpan(
        style: pw.TextStyle(fontSize: fontSize),
        children: spans,
      ),
      textAlign: pw.TextAlign.left,
      // 允许含图片/公式的富文本跨页拆分, 避免 PdfTooBigPageException
      overflow: pw.TextOverflow.span,
    );
  }
}

/// 预取到的图片数据 (字节 + 是否 SVG)
class _ImgData {
  final Uint8List bytes;
  final bool isSvg;
  _ImgData(this.bytes, this.isSvg);
}

/// 导出字段配置
///
/// 控制导出 PDF 时包含哪些题目字段, 对齐 Python 的 fields 参数.
class AnswerExportFields {
  final bool showQuestionContent;
  final bool showOptions;
  final bool showAnswer;
  final bool showKnowledge;
  final bool showDifficulty;
  final bool showAnalysis;
  final bool showQuestionType;

  const AnswerExportFields({
    this.showQuestionContent = true,
    this.showOptions = true,
    this.showAnswer = true,
    this.showKnowledge = true,
    this.showDifficulty = true,
    this.showAnalysis = true,
    this.showQuestionType = true,
  });

  /// 全部字段 (默认)
  static const all = AnswerExportFields();

  /// 仅试题 (不含答案/解析/知识点, 对齐 Python _download_paper)
  static const paperOnly = AnswerExportFields(
    showAnswer: false,
    showKnowledge: false,
    showAnalysis: false,
  );
}
