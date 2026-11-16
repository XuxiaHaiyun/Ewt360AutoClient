/// 图片生成服务，为主观题生成 attachmentImages：固定图片 / 按答案解析渲染 HTML（含手写模拟）/ 编辑器画布导出。
/// renderContext 必须是能拿到 Overlay 的 context，否则 generate/editor 模式回退到固定图片。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_html/flutter_html.dart';

import '../../presentation/widgets/ewt_html_render.dart'
    show buildEwtHtmlExtensions, ewtHtmlStyle;
import '../../presentation/widgets/handwritten_page.dart'
    show HandwrittenPage;
import '../../../editor/domain/services/editor_export_service.dart';
import '../entities/handwriting_config.dart';
import '../entities/image_upload_config.dart';
import '../entities/question_info.dart';

/// 图片生成服务
///
/// 为图片上传类题型 (主观题) 生成 attachmentImages:
/// - [ImageUploadMode.fixed]: 使用固定图片 (assets/images/onlyhead.png)
/// - [ImageUploadMode.generate]: 根据答案/解析动态生成图片
///   - 普通渲染: 与答案展示页一致 —— [flutter_html] 的 [Html] widget
///   - 手写模拟: [ImageUploadConfig.handwriting] 启用时, 通过 [HandwrittenPage]
///     逐字绘制 (自定义字体/倾斜/涂改/纸张背景/公式图片模拟手绘)
///
/// 生成模式 (generate) 的渲染方式:
/// **与答案展示页完全一致** —— 使用 [flutter_html] 的 [Html] widget 渲染
/// 答案/解析 HTML (含 `<img>` 标签的 SVG 公式 / 位图扩展),
/// 通过 `Overlay` + `RepaintBoundary` 在屏幕外完成布局与图片加载,
/// 然后截图为 PNG 字节。
///
/// 这样可正确渲染:
/// - 数学公式 (file.ewt360.com 返回的 SVG, 由 [SvgPicture.string] 绘制)
/// - 题干配图 (PNG/JPG 位图)
/// - HTML 标签 (粗体/列表/段落等)
///
/// 注意: [ImageUploadMode.custom] 不在此生成 (用户已选本机图片),
/// 由 [AnswerSubmitService._buildQuestionListWithImages] 直接上传用户图片,
/// 此处 [generateImageBytes] 对 custom 返回 null (不参与生成)。
class ImageGenerationService {
  /// 单例
  static final ImageGenerationService instance = ImageGenerationService._();

  ImageGenerationService._();

  /// 固定图片字节缓存 (assets/images/onlyhead.png)
  Uint8List? _fixedImageBytes;

  /// 用于挂载渲染 Overlay 的 [BuildContext] (由调用方注入)。
  ///
  /// 必须是能拿到 [Overlay] 的 context (如 [AnswerResultPage] 的 context)。
  /// 为 null 时, generate 模式回退到固定图片 (无法渲染 HTML/公式)。
  BuildContext? renderContext;

  /// 为单个题目生成图片并返回字节 (PNG)
  ///
  /// [config] 图片上传配置
  /// [question] 题目信息 (使用其 answer/analysis 字段)
  /// [subjectName] 课程学科名 (如 "语文"), 用于"仅特定学科显示解析"过滤
  ///
  /// 返回 PNG 字节, 失败时返回 null。
  Future<Uint8List?> generateImageBytes({
    required ImageUploadConfig config,
    required QuestionInfo question,
    String subjectName = '',
  }) async {
    try {
      switch (config.mode) {
        case ImageUploadMode.fixed:
          return await _loadFixedImage(config.fixedImagePath);
        case ImageUploadMode.generate:
          return await _generateFromContent(
            question: question,
            includeAnswer: config.includeAnswer,
            // 仅特定学科显示解析: 学科命中集合才包含解析 (空集合 = 全部)
            includeAnalysis: config.shouldShowAnalysisFor(subjectName),
            hideAnswerContainsAnalysis: config.hideAnswerContainsAnalysis,
            handwriting: config.handwriting,
          );
        case ImageUploadMode.custom:
          // custom 模式不生成图片 (用户已选本机图片),
          // 由调用方 _buildQuestionListWithImages 直接上传用户图片。
          return null;
        case ImageUploadMode.editor:
          // 编辑器模式: 把编辑器画布渲染为 PNG 上传
          final editorConfig = config.editor;
          if (editorConfig == null) {
            return await _loadFixedImage('assets/images/onlyhead.png');
          }
          final context = renderContext;
          if (context == null) {
            return await _loadFixedImage('assets/images/onlyhead.png');
          }
          return await EditorExportService.instance
                  .exportPng(context, editorConfig) ??
              await _loadFixedImage('assets/images/onlyhead.png');
      }
    } catch (_) {
      return null;
    }
  }

  /// 批量生成图片字节
  ///
  /// 为每个主观题生成 PNG 字节, 由调用方负责上传到 OSS。
  ///
  /// 返回: {questionId: 图片字节}, 失败的题目不包含在结果中。
  Future<Map<String, Uint8List>> generateForQuestions({
    required ImageUploadConfig config,
    required List<QuestionInfo> questions,
    String subjectName = '',
  }) async {
    final result = <String, Uint8List>{};
    for (final q in questions) {
      if (!q.subjective && q.childQuestions.isEmpty) continue;
      if (q.id.isEmpty) continue;
      final bytes = await generateImageBytes(
        config: config,
        question: q,
        subjectName: subjectName,
      );
      if (bytes != null) {
        result[q.id] = bytes;
      }
    }
    return result;
  }

  /// 加载固定图片 (assets/images/onlyhead.png)
  Future<Uint8List> _loadFixedImage(String assetPath) async {
    if (_fixedImageBytes != null && assetPath == 'assets/images/onlyhead.png') {
      return _fixedImageBytes!;
    }
    final bytes = await rootBundle.load(assetPath);
    final result = bytes.buffer.asUint8List();
    if (assetPath == 'assets/images/onlyhead.png') {
      _fixedImageBytes = result;
    }
    return result;
  }

  /// 根据题目内容生成图片 (与答案展示页一致的 HTML 渲染)
  ///
  /// 流程:
  /// 1. 拼接答案/解析 HTML (含 `<img>` 公式标签), 与答案展示页 `_AnswerContent` +
  ///    "解析" 字段渲染逻辑一致。
  /// 2. 若内容为空, 回退到固定图片。
  /// 3. 渲染方式:
  ///    - [ImageUploadConfig.handwriting] 启用时, 用 [HandwrittenPage]
  ///      逐字手写渲染 (字体/倾斜/涂改/纸张/公式模拟手绘);
  ///    - 否则通过 [Overlay] + [RepaintBoundary] 在屏幕外挂载 [Html] widget,
  ///      等待网络图片 (公式 SVG / 题干位图) 加载完成后截图为 PNG。
  ///
  /// 等待策略:
  /// - 网络图片加载由 [_EwtNetworkImage] 内部 Future 异步完成。
  /// - 渲染后等待 [imageLoadTimeout] 让所有图片加载并完成首帧绘制。
  /// - 等待期间通过 pump 触发 widget tree 更新, 加速图片加载完成。
  ///
  /// 失败时回退到固定图片 (assets/images/onlyhead.png)。
  Future<Uint8List> _generateFromContent({
    required QuestionInfo question,
    required bool includeAnswer,
    required bool includeAnalysis,
    bool hideAnswerContainsAnalysis = false,
    HandwritingConfig? handwriting,
  }) async {
    // 1. 拼接 HTML 内容 (与答案展示页一致, 不显示"答案"/"解析"标签)
    final htmlBuffer = StringBuffer();
    if (includeAnswer) {
      final answerHtml = question.answer.trim();
      if (answerHtml.isNotEmpty && answerHtml != '(主观题)') {
        // 答案含"见解析"不展示: 勾选后自动剔除答案内容
        if (!(hideAnswerContainsAnalysis &&
            _containsAnalysisPlaceholder(answerHtml))) {
          htmlBuffer.writeln(answerHtml);
        }
      }
    }
    if (includeAnalysis) {
      final analysisHtml = question.analysis.trim();
      if (analysisHtml.isNotEmpty) {
        htmlBuffer.writeln(analysisHtml);
      }
    }

    final html = htmlBuffer.toString().trim();
    if (html.isEmpty) {
      return await _loadFixedImage('assets/images/onlyhead.png');
    }

    // 2. 无 renderContext 时, 回退到固定图片 (无法渲染 HTML)
    final context = renderContext;
    if (context == null) {
      return await _loadFixedImage('assets/images/onlyhead.png');
    }

    // 3. 手写模拟渲染 (逐字手写风格)
    if (handwriting != null) {
      return await _renderWidgetToPng(
            context,
            (ctx) => HandwrittenPage(
              html: html,
              config: handwriting,
              width: 1080,
            ),
          ) ??
          await _loadFixedImage('assets/images/onlyhead.png');
    }

    // 4. 默认: 通过 Overlay 渲染 Html widget 并截图
    return await _renderHtmlToPng(context, html) ??
        await _loadFixedImage('assets/images/onlyhead.png');
  }

  /// 检测答案 HTML 中是否含"见解析"字样 (忽略标签, 兼容换行/空白)
  static bool _containsAnalysisPlaceholder(String html) {
    return _stripHtmlText(html).contains('见解析');
  }

  /// 去除 HTML 标签后取纯文本
  static String _stripHtmlText(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'\s'), '');
  }

  /// 通过 [Overlay] 在屏幕外渲染 [Html] widget, 截图为 PNG 字节
  ///
  /// 实现:
  /// - 用 [OverlayEntry] + [Positioned] 把 widget 放到屏幕外 (-10000, -10000)
  /// - 用 `SizedBox(width)` 给 Html 固定宽度, 高度自适应 (避免底部留白)
  /// - 等待网络图片加载 (默认 5s, 多次 pump 触发 build)
  /// - 通过 [RepaintBoundary.toImage] 截图
  /// - 失败/超时返回 null
  Future<Uint8List?> _renderHtmlToPng(
    BuildContext context,
    String html, {
    double width = 1080,
    Duration imageLoadTimeout = const Duration(seconds: 5),
  }) {
    return _renderWidgetToPng(
      context,
      (ctx) => Html(
        data: html,
        style: ewtHtmlStyle(Theme.of(ctx)),
        extensions: buildEwtHtmlExtensions(),
        shrinkWrap: true,
      ),
      width: width,
      imageLoadTimeout: imageLoadTimeout,
    );
  }

  /// 通过 [Overlay] 在屏幕外渲染任意 widget, 截图为 PNG 字节
  ///
  /// [builder] 负责构建待截图的 widget (Html / HandwrittenPage 等),
  /// 其尺寸须由内容决定 (或显式指定), 截图区域 = RepaintBoundary 内容区域。
  /// 失败/超时返回 null。
  Future<Uint8List?> _renderWidgetToPng(
    BuildContext context,
    Widget Function(BuildContext) builder, {
    double width = 1080,
    Duration imageLoadTimeout = const Duration(seconds: 5),
  }) async {
    OverlayEntry? entry;
    try {
      final overlay = Overlay.of(context, rootOverlay: true);
      final boundaryKey = GlobalKey();

      // Align + SizedBox(width): 固定宽度约束, 不限高度
      // RepaintBoundary 紧贴内容大小, 截图无空白
      // Material: 提供 Canvas 所需的 Material 祖先 (Html 内部部分 widget 需要)
      final widget = Positioned(
        left: -10000,
        top: -10000,
        child: Material(
          color: Colors.white,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              widthFactor: 1,
              child: SizedBox(
                width: width,
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: builder(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      entry = OverlayEntry(builder: (_) => widget);
      overlay.insert(entry);

      // 等待 widget 挂载 + 网络图片加载, 多次 pump 触发渲染管线
      final end = DateTime.now().add(imageLoadTimeout);
      while (DateTime.now().isBefore(end)) {
        await _pump(const Duration(milliseconds: 200));
      }

      // 截图
      final boundary = boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null || !boundary.attached || !boundary.hasSize) {
        return null;
      }

      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      entry?.remove();
    }
  }

  /// 触发 widget tree 更新 (等待图片加载)
  ///
  /// 调度下一帧并延迟, 让 widget tree 完成 build/layout/paint,
  /// 推进图片加载状态机。
  Future<void> _pump(Duration duration) async {
    WidgetsBinding.instance.scheduleFrame();
    await Future.delayed(duration);
  }
}
