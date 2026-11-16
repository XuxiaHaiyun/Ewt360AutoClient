/// 手写模拟渲染页，把答案/解析 HTML 逐字绘制成接近真实手写的页面（倾斜/起伏/弯曲/涂改/纸张背景）。
/// 布局完成后自身尺寸即内容尺寸，供上层经 RepaintBoundary 截图生成 PNG。
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:html/dom.dart' as htmldom;
import 'package:html/parser.dart' as html_parser;

import '../../domain/entities/handwriting_config.dart';
import 'ewt_html_render.dart' show ewtCdnHeaders, loadEwtImageData;

/// 手写模拟渲染页
///
/// 把答案/解析 HTML (含 `<img>` 公式与配图) 渲染成接近真实手写的页面:
/// - 使用 [HandwritingConfig] 控制字体/字号/倾斜/行距/纸张/涂改/弯曲度等
/// - 逐字绘制: 每个字符独立旋转、基线起伏、字号与墨色随机变化,
///   整行按正弦曲线弯曲 + 线性漂移, 模拟真实书写走线
/// - 公式与图片按 [HandwritingConfig.imageCurvature] 轻微旋转嵌入
/// - 可选涂改: 在随机位置绘制划线修正 (单线/双线/波浪)
/// - 纸张背景: 空白/横线/方格/田字格, 线距线色纸色可调
///
/// 布局完成后自身尺寸 = 内容尺寸, 供上层 (ImageGenerationService)
/// 通过 RepaintBoundary 截图生成 PNG。
///
/// 用法:
/// ```dart
/// SizedBox(
///   width: 1080,
///   child: HandwrittenPage(html: html, config: config, width: 1080),
/// )
/// ```
class HandwrittenPage extends StatefulWidget {
  /// 待渲染的 HTML 内容 (答案/解析)
  final String html;

  /// 手写模拟配置
  final HandwritingConfig config;

  /// 页面内容宽度 (px, 不含页边距由配置 margin 决定)
  final double width;

  const HandwrittenPage({
    super.key,
    required this.html,
    required this.config,
    required this.width,
  });

  @override
  State<HandwrittenPage> createState() => _HandwrittenPageState();
}

class _HandwrittenPageState extends State<HandwrittenPage> {
  HwLayoutResult? _layout;
  String? _fontFamily;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void didUpdateWidget(covariant HandwrittenPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        oldWidget.config != widget.config ||
        oldWidget.width != widget.width) {
      _build();
    }
  }

  Future<void> _build() async {
    final config = widget.config;
    // 1. 解析字体 (内置/系统/自定义 TTF)
    final family = await HandwritingFontResolver.resolveFamily(config.font);
    if (!mounted) return;
    _fontFamily = family;

    // 2. 解析 HTML → 段落/文本/图片 token
    final paragraphs = HandwritingHtmlParser.parse(widget.html);

    // 3. 预加载所有内嵌图片 (公式 SVG / 配图), 并行
    final srcs = <String>[];
    for (final p in paragraphs) {
      for (final t in p.tokens) {
        if (t is HwImageToken && !srcs.contains(t.src)) srcs.add(t.src);
      }
    }
    final images = <String, HwImageAsset>{};
    await Future.wait(srcs.map((src) async {
      final asset = await _loadAsset(src);
      if (asset != null) images[src] = asset;
    }));
    if (!mounted) return;

    // 4. 计算布局 (逐字坐标/旋转/字号 + 图片坐标 + 涂改位置)
    final layout = HwLayoutEngine(
      config: config,
      width: widget.width,
      fontFamily: family,
      images: images,
    ).layout(paragraphs);
    if (!mounted) return;
    setState(() => _layout = layout);
  }

  Future<HwImageAsset?> _loadAsset(String src) async {
    try {
      final data = await loadEwtImageData(src, headers: ewtCdnHeaders);
      if (data.svgText != null) {
        return HwImageAsset.svg(data.svgText!, _svgSize(data.svgText!));
      }
      if (data.rasterBytes != null) {
        final size = await _rasterSize(data.rasterBytes!);
        if (size == null) return null;
        return HwImageAsset.raster(data.rasterBytes!, size);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 从 SVG 文本提取 viewBox 尺寸 (默认 100x100)
  static Size _svgSize(String svg) {
    final m = RegExp(
      r'viewBox="\s*(-?[\d.]+)[,\s]+(-?[\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)"',
    ).firstMatch(svg);
    if (m != null) {
      final w = double.tryParse(m.group(3) ?? '');
      final h = double.tryParse(m.group(4) ?? '');
      if (w != null && h != null && w > 0 && h > 0) return Size(w, h);
    }
    final wm = RegExp(r'width="([\d.]+)').firstMatch(svg);
    final hm = RegExp(r'height="([\d.]+)').firstMatch(svg);
    final w = wm == null ? null : double.tryParse(wm.group(1) ?? '');
    final h = hm == null ? null : double.tryParse(hm.group(1) ?? '');
    if (w != null && w > 0 && h != null && h > 0) return Size(w, h);
    return const Size(100, 100);
  }

  static Future<Size?> _rasterSize(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final size = Size(img.width.toDouble(), img.height.toDouble());
      img.dispose();
      codec.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    if (layout == null) {
      return SizedBox(
        width: widget.width,
        height: 200,
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final config = widget.config;
    return SizedBox(
      width: widget.width,
      height: layout.height,
      child: Stack(
        children: [
          // 纸张背景 + 文字 (一个画布)
          CustomPaint(
            size: Size(widget.width, layout.height),
            painter: _HandwritingPainter(
              config: config,
              layout: layout,
              fontFamily: _fontFamily ?? 'LXGWWenKai',
            ),
          ),
          // 内嵌图片 (公式/配图) 以 widget 形式叠加, 轻旋转模拟手绘
          ...layout.images.map((img) {
            final asset = layout.assetOf(img.src);
            Widget child;
            if (asset is HwImageAsset && asset.svg != null) {
              child = SvgPicture.string(
                asset.svg!,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              );
            } else if (asset is HwImageAsset && asset.bytes != null) {
              child = Image.memory(
                asset.bytes!,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
                gaplessPlayback: true,
              );
            } else {
              child = const SizedBox.shrink();
            }
            return Positioned(
              left: img.x,
              top: img.y,
              width: img.w,
              height: img.h,
              child: Transform.rotate(
                angle: img.angle * pi / 180,
                child: child,
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ─────────────────────────── HTML 解析 ───────────────────────────

/// 段落
class HwParagraph {
  final List<HwToken> tokens;
  const HwParagraph(this.tokens);
}

/// 段落内 token: 文本 或 图片
sealed class HwToken {
  const HwToken();
}

/// 文本 token (已按空格分词, 保留中文逐字)
class HwTextToken extends HwToken {
  final String text;
  const HwTextToken(this.text);

  @override
  String toString() => 'Txt($text)';
}

/// 图片 token (公式 SVG / 配图)
class HwImageToken extends HwToken {
  final String src;
  const HwImageToken(this.src);

  @override
  String toString() => 'Img($src)';
}

/// HTML → 段落列表
///
/// 规则:
/// - `p/div/li/h1~h6/br/table 行` 等块级元素作为段落分隔
/// - `<img>` 作为图片 token
/// - 文本空白折叠为单个空格; 中文字符间多余空格剔除
class HandwritingHtmlParser {
  static List<HwParagraph> parse(String html) {
    final doc = html_parser.parse(html);
    final paragraphs = <HwParagraph>[];
    final current = <HwToken>[];

    void flush() {
      if (current.isEmpty) return;
      paragraphs.add(HwParagraph(_cleanUp(current)));
      current.clear();
    }

    void addText(String text) {
      var t = text.replaceAll(RegExp(r'\s+'), ' ');
      if (t.isEmpty) return;
      // 剔除中文之间的空格 (如 "答案 见解析" → "答案见解析")
      t = t.replaceAllMapped(
        RegExp(r'(?<=[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef，。；：！？、（）]) '
            r'(?=[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef，。；：！？、（）])'),
        (_) => '',
      );
      if (current.isNotEmpty && current.last is HwTextToken) {
        final last = current.last as HwTextToken;
        if (last.text.endsWith(' ')) {
          current[current.length - 1] =
              HwTextToken('${last.text.substring(0, last.text.length - 1)}$t');
          return;
        }
      }
      current.add(HwTextToken(t));
    }

    void walk(htmldom.Node node) {
      if (node is htmldom.Text) {
        addText(node.text);
        return;
      }
      if (node is! htmldom.Element) return;
      final name = node.localName ?? '';
      if (name == 'br') {
        flush();
        return;
      }
      if (name == 'img') {
        final src = node.attributes['src'] ?? '';
        if (src.isNotEmpty) {
          var s = src;
          if (s.startsWith('//')) {
            s = 'https:$s';
          } else if (s.startsWith('http://')) {
            s = 'https://${s.substring(7)}';
          }
          current.add(HwImageToken(s));
        }
        return;
      }
      const blockTags = {
        'p', 'div', 'li', 'ul', 'ol', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
        'table', 'tr', 'td', 'th', 'section', 'blockquote', 'pre', 'hr',
        'tbody', 'thead', 'caption',
      };
      const skipTags = {'script', 'style', 'head', 'meta', 'link'};
      if (skipTags.contains(name)) return;
      if (blockTags.contains(name)) flush();
      // 注意: 必须遍历 node.nodes (含文本节点), children 只含元素节点,
      // 会丢失 <p>文本</p> 中的纯文本
      for (final c in node.nodes) {
        walk(c);
      }
      if (blockTags.contains(name)) flush();
    }

    walk(doc.body ?? doc);
    flush();
    return paragraphs;
  }

  /// 按空格拆分为 token 序列, 连续空白折叠
  static List<HwToken> _cleanUp(List<HwToken> tokens) {
    final result = <HwToken>[];
    for (final t in tokens) {
      if (t is HwTextToken) {
        final parts = t.text.split(' ').where((s) => s.isNotEmpty).toList();
        for (int i = 0; i < parts.length; i++) {
          if (i > 0) result.add(const HwTextToken(' '));
          result.add(HwTextToken(parts[i]));
        }
      } else {
        result.add(t);
      }
    }
    // 去掉段首尾的空格 token
    while (result.isNotEmpty && result.first is HwTextToken && (result.first as HwTextToken).text == ' ') {
      result.removeAt(0);
    }
    while (result.isNotEmpty && result.last is HwTextToken && (result.last as HwTextToken).text == ' ') {
      result.removeLast();
    }
    return result;
  }
}

// ─────────────────────────── 图片资源 ───────────────────────────

/// 已加载的内嵌图片资源
class HwImageAsset {
  final Uint8List? bytes; // 位图字节 (svg 为空)
  final String? svg; // SVG 文本 (bytes 为空)
  final Size size; // 固有尺寸 (px)

  const HwImageAsset.raster(Uint8List this.bytes, this.size) : svg = null;
  const HwImageAsset.svg(String this.svg, this.size) : bytes = null;
}

// ─────────────────────────── 布局 ───────────────────────────

/// 布局结果: 逐字/逐图放置数据
class HwLayoutResult {
  final List<HwPlacedText> texts;
  final List<HwPlacedImage> images;
  final List<HwScratchBox> scratches;
  final Map<String, HwImageAsset> assets;
  final double height;
  final double lineHeightPx;

  const HwLayoutResult({
    required this.texts,
    required this.images,
    required this.scratches,
    required this.assets,
    required this.height,
    required this.lineHeightPx,
  });

  HwImageAsset? assetOf(String src) => assets[src];
}

/// 单个字符的放置信息
class HwPlacedText {
  final String char;
  final double x;
  final double y; // 字符 top 坐标
  final double size; // 实际字号
  final double angle; // 旋转 (度)
  final double alpha; // 墨色浓度 0~1
  final int passes; // 笔画叠加次数 (粗细)
  final double offsetX;
  final double offsetY;

  const HwPlacedText({
    required this.char,
    required this.x,
    required this.y,
    required this.size,
    required this.angle,
    required this.alpha,
    required this.passes,
    required this.offsetX,
    required this.offsetY,
  });
}

/// 内嵌图片的放置信息
class HwPlacedImage {
  final String src;
  final double x;
  final double y;
  final double w;
  final double h;
  final double angle; // 旋转 (度)

  const HwPlacedImage({
    required this.src,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.angle,
  });
}

/// 涂改位置 (划线覆盖区域)
class HwScratchBox {
  final double x;
  final double y;
  final double w;
  final double h;
  const HwScratchBox(this.x, this.y, this.w, this.h);
}

/// 布局引擎
///
/// 贪心换行, 逐字生成随机化放置参数:
/// - 基线起伏 [HandwritingConfig.baselineJitter]
/// - 字号变化 [HandwritingConfig.fontSizeJitter]
/// - 倾斜 [HandwritingConfig.tiltAngle] + [HandwritingConfig.tiltJitter]
/// - 整行正弦弯曲 [HandwritingConfig.lineWaviness] + 随机线性漂移
class HwLayoutEngine {
  final HandwritingConfig config;
  final double width;
  final String fontFamily;
  final Map<String, HwImageAsset> images;

  /// 单字测量缓存
  final Map<String, double> _widthCache = {};
  final Random _random;
  final double _s; // scale 快捷

  HwLayoutEngine({
    required this.config,
    required this.width,
    required this.fontFamily,
    required this.images,
  })  : _random = Random(config.randomSeed),
        _s = config.scale;

  double get _fontSize => config.fontSize * _s;
  double get _margin => config.margin * _s;
  double get _lineSpacingPx =>
      max(_fontSize * config.lineHeight, _fontSize * 1.35);
  double get _maxWidth => max(120, width - _margin * 2);

  double _charWidth(String ch, double size) {
    final key = '$ch@${size.toStringAsFixed(1)}';
    final hit = _widthCache[key];
    if (hit != null) return hit;
    final w = measureTextWidth(ch, size);
    _widthCache[key] = w;
    return w;
  }

  double measureTextWidth(String text, double size) {
    final paragraph = _charParagraph(text, size, 1);
    // 注意: 有限宽度约束下 longestLine 才是真实文本宽度,
    // 传 double.infinity 时 paragraph.width 会返回 Infinity (Flutter quirk)
    return paragraph.longestLine;
  }

  /// 构造单字/单词段落 (用于测量宽度)
  ui.Paragraph _charParagraph(String text, double size, double alpha) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontSize: size,
      fontFamily: fontFamily,
      textDirection: ui.TextDirection.ltr,
    ))
      ..pushStyle(ui.TextStyle(
        color: config.inkColor.withValues(alpha: alpha),
        fontSize: size,
        // 必须在 TextStyle 里也带上 fontFamily, 否则引擎只按 fallback 解析
        // (fallback 字不在系统时全部落到默认字体, 手写字体选择不生效)
        fontFamily: fontFamily,
        letterSpacing: config.letterSpacing * _s,
      ))
      ..addText(text);
    final paragraph = builder.build();
    paragraph.layout(const ui.ParagraphConstraints(width: 1e5));
    return paragraph;
  }

  HwLayoutResult layout(List<HwParagraph> paragraphs) {
    final texts = <HwPlacedText>[];
    final placedImages = <HwPlacedImage>[];
    final scratches = <HwScratchBox>[];
    final scratchCandidates = <HwPlacedText>[];

    final lineHeightPx = _lineSpacingPx;
    double yCursor = _margin;
    // 每行随机漂移 (整行逐渐上抬/下沉), 模拟手写行位漂移
    double drift = (_random.nextDouble() * 2 - 1) * _fontSize * 0.03;

    for (final para in paragraphs) {
      // 段落内逐 token 贪心换行
      final currentLine = <HwLineItem>[];
      double lineWidth = 0;

      void flushLine() {
        if (currentLine.isEmpty) return;
        final wavePhase = _random.nextDouble() * 2 * pi;
        final waveFreq = 2 * pi / max(1.0, _maxWidth * 0.9);
        final waveAmp = config.lineWaviness * _s;
        // 本行最高图像高度 (决定行高, 防止公式与上行重叠)
        double maxImageH = 0;
        for (final item in currentLine) {
          if (item is HwImageItem && item.h > maxImageH) maxImageH = item.h;
        }
        final baseline = yCursor + _fontSize * 0.85 + drift;
        double x = _margin;
        for (final item in currentLine) {
          if (item is HwTextItem) {
            if (item.text == ' ') {
              x += item.width;
              continue;
            }
            final sizeJitter = config.fontSizeJitter * _random.nextDouble() -
                config.fontSizeJitter / 2;
            final size = item.size * (1 + sizeJitter);
            final wobble = waveAmp * sin(x * waveFreq + wavePhase) +
                (_random.nextDouble() * 2 - 1) *
                    (config.baselineJitter * _s);
            final angle = config.tiltAngle +
                (config.tiltJitter * (_random.nextDouble() * 2 - 1));
            final alpha = max(
                0.55,
                1 - config.pressureJitter * _random.nextDouble() -
                    (config.strokeWidth < 1 ? (1 - config.strokeWidth) * 0.25 : 0));
            final passes = config.strokeWidth > 1.05
                ? min(4, ((config.strokeWidth - 1) * 4).round())
                : 1;
            final placed = HwPlacedText(
              char: item.text,
              x: x,
              y: baseline - item.size * 0.85 + wobble,
              size: size,
              angle: angle,
              alpha: alpha,
              passes: passes,
              offsetX: (_random.nextDouble() * 2 - 1) * 1.2,
              offsetY: (_random.nextDouble() * 2 - 1) * 1.2,
            );
            texts.add(placed);
            if (config.scratchOut && placed.char.trim().isNotEmpty) {
              scratchCandidates.add(placed);
            }
            x += item.width;
          } else {
            final im = item as HwImageItem;
            final angle = (config.imageCurvature * _random.nextDouble() * 2 - 1) *
                config.imageCurvature *
                3;
            placedImages.add(HwPlacedImage(
              src: im.src,
              x: x,
              y: baseline - im.h,
              w: im.w,
              h: im.h,
              angle: angle,
            ));
            x += im.w + 4;
          }
        }
        yCursor += max(lineHeightPx, maxImageH) + drift * 0.3;
        drift = (drift + (_random.nextDouble() - 0.5) * _fontSize * 0.015)
            .clamp(-_fontSize * 0.06, _fontSize * 0.06);
        currentLine.clear();
        lineWidth = 0;
      }

      void addToLine(HwLineItem item) {
        if (lineWidth + item.width > _maxWidth && currentLine.isNotEmpty) {
          flushLine();
          if (item is HwTextItem && item.text == ' ') return;
        }
        currentLine.add(item);
        lineWidth += item.width;
      }

      for (final token in para.tokens) {
        if (token is HwTextToken) {
          _addTextToken(token.text, addToLine);
        } else if (token is HwImageToken) {
          final asset = images[token.src];
          if (asset == null) {
            _addTextToken('[图片]', addToLine);
            continue;
          }
          final maxImgW = _maxWidth * 0.8;
          var iw = asset.size.width;
          var ih = asset.size.height;
          // 限制最大宽度, 按比例缩放高度
          if (iw > maxImgW) {
            final sc = maxImgW / iw;
            iw *= sc;
            ih *= sc;
          }
          // 高度上限 (单个公式不宜超过 3.2 倍字号)
          final maxImgH = _fontSize * 3.2;
          if (ih > maxImgH) {
            final sc = maxImgH / ih;
            iw *= sc;
            ih *= sc;
          }
          if (iw < 1 || ih < 1) {
            _addTextToken('[图片]', addToLine);
            continue;
          }
          addToLine(HwImageItem(token.src, iw, ih));
        }
      }
      flushLine();
      yCursor += lineHeightPx * 0.45; // 段间距
      drift = (_random.nextDouble() - 0.5) * _fontSize * 0.02;
    }

    // 涂改: 随机选 N 处字符覆盖划线
    if (config.scratchOut && scratchCandidates.isNotEmpty) {
      final count = min(config.scratchOutCount, scratchCandidates.length);
      final idx = <int>{};
      while (idx.length < count) {
        idx.add(_random.nextInt(scratchCandidates.length));
      }
      for (final i in idx) {
        final c = scratchCandidates[i];
        scratches.add(HwScratchBox(
          c.x - 2,
          c.y + c.size * 0.15,
          c.size + 4,
          c.size * 0.7,
        ));
      }
    }

    final height = yCursor - lineHeightPx * 0.45 + _margin * 0.4;
    return HwLayoutResult(
      texts: texts,
      images: placedImages,
      scratches: scratches,
      assets: images,
      height: max(100, height),
      lineHeightPx: lineHeightPx,
    );
  }

  /// 把文本按中文逐字 / 拉丁成词拆分为 line item
  void _addTextToken(String text, void Function(HwLineItem) add) {
    if (text.isEmpty) return;
    final isCjk = RegExp(r'[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]');
    String? word;
    void flushWord() {
      if (word == null || word!.isEmpty) return;
      add(HwTextItem(word!, _charWidth(word!, _fontSize),
          size: _fontSize));
      word = null;
    }

    for (final ch in text.split('')) {
      if (ch == ' ') {
        flushWord();
        add(HwTextItem(' ', config.wordSpacing * _s));
      } else if (isCjk.hasMatch(ch)) {
        flushWord();
        add(HwTextItem(ch, _charWidth(ch, _fontSize), size: _fontSize));
      } else {
        word = (word ?? '') + ch;
      }
    }
    flushWord();
  }
}

/// 行内条目
sealed class HwLineItem {
  final double width;
  const HwLineItem(this.width);
}

class HwTextItem extends HwLineItem {
  final String text;
  final double size;
  HwTextItem(this.text, double width, {double? size})
      : size = size ?? width * 0.95,
        super(width);
}

class HwImageItem extends HwLineItem {
  final String src;
  final double w;
  final double h;
  HwImageItem(this.src, this.w, this.h) : super(w);
}

// ─────────────────────────── 绘制 ───────────────────────────

/// 手写页面画笔: 纸张背景 + 文字 + 涂改
class _HandwritingPainter extends CustomPainter {
  final HandwritingConfig config;
  final HwLayoutResult layout;
  final String fontFamily;
  final Map<String, ui.Paragraph> _tpCache = {};
  final double _s;

  _HandwritingPainter({
    required this.config,
    required this.layout,
    required this.fontFamily,
  }) : _s = config.scale;

  ui.Paragraph _charParagraph(String ch, double size, double alpha) {
    final key = '$ch@${size.toStringAsFixed(1)}@${alpha.toStringAsFixed(2)}';
    final hit = _tpCache[key];
    if (hit != null) return hit;
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontSize: size,
      fontFamily: fontFamily,
      textDirection: ui.TextDirection.ltr,
    ))
      ..pushStyle(ui.TextStyle(
        color: config.inkColor.withValues(alpha: alpha),
        fontSize: size,
        // 必须与 ParagraphStyle 一致 (见 HwLayoutEngine 同名函数注释)
        fontFamily: fontFamily,
        letterSpacing: config.letterSpacing * _s,
      ))
      ..addText(ch);
    final paragraph = builder.build();
    paragraph.layout(const ui.ParagraphConstraints(width: 1e5));
    if (_tpCache.length > 4000) _tpCache.clear();
    _tpCache[key] = paragraph;
    return paragraph;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintPaper(canvas, size);
    _paintText(canvas);
    _paintScratches(canvas);
  }

  /// 纸张背景与线条
  void _paintPaper(Canvas canvas, Size size) {
    final bg = Paint()..color = config.paperColor;
    canvas.drawRect(Offset.zero & size, bg);

    final line = Paint()
      ..color = config.paperLineColor.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    final light = Paint()
      ..color = config.paperLineColor.withValues(alpha: 0.3)
      ..strokeWidth = 0.7;
    final spacing = max(12.0, config.paperLineSpacing * _s);
    final margin = config.margin * _s;

    switch (config.paperType) {
      case HandwritingPaperType.blank:
        break;
      case HandwritingPaperType.ruled:
        for (double y = margin; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
        }
        break;
      case HandwritingPaperType.grid:
        for (double y = margin; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
        }
        for (double x = margin; x < size.width; x += spacing) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
        }
        break;
      case HandwritingPaperType.tianzige:
        // 横向线 (整页宽) + 每个方格内的 "田" 字对角线
        for (double y = margin; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
          for (double x = margin; x < size.width; x += spacing) {
            final x2 = min(x + spacing, size.width);
            final y2 = min(y + spacing, size.height);
            canvas.drawLine(Offset(x, y), Offset(x2, y2), light);
            canvas.drawLine(Offset(x2, y), Offset(x, y2), light);
          }
        }
        // 纵向线 (整页高), 与横向线共同围成方格
        for (double x = margin; x < size.width; x += spacing) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
        }
        break;
    }
  }

  /// 逐字绘制 (含笔画叠加与旋转)
  void _paintText(Canvas canvas) {
    for (final t in layout.texts) {
      final para = _charParagraph(t.char, t.size, t.alpha);
      final passes = t.passes;
      canvas.save();
      // 中心旋转: 字符以其中心为轴旋转
      final cx = t.x + t.size / 2;
      final cy = t.y + t.size / 2;
      canvas.translate(cx, cy);
      canvas.rotate(t.angle * pi / 180);
      canvas.translate(-cx, -cy);
      for (int p = 0; p < passes; p++) {
        final ox = p == 0 ? t.offsetX : (_s * (p * 0.7));
        final oy = p == 0 ? t.offsetY : (_s * (p * 0.7));
        canvas.drawParagraph(para, Offset(t.x + ox, t.y + oy));
      }
      canvas.restore();
    }
  }

  /// 涂改划线
  void _paintScratches(Canvas canvas) {
    final paint = Paint()
      ..color = config.scratchOutColor
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final s in layout.scratches) {
      final midY = s.y + s.h / 2;
      switch (config.scratchOutStyle) {
        case ScratchOutStyle.singleLine:
          _drawScratchLine(canvas, paint, s.x, s.x + s.w, midY);
        case ScratchOutStyle.doubleLine:
          _drawScratchLine(canvas, paint, s.x, s.x + s.w, s.y + s.h * 0.35);
          _drawScratchLine(canvas, paint, s.x, s.x + s.w, s.y + s.h * 0.7);
        case ScratchOutStyle.wave:
          final path = Path();
          final amp = s.h * 0.28;
          final periods = 2.0;
          path.moveTo(s.x, midY);
          for (int i = 1; i <= 12; i++) {
            final fx = s.x + s.w * i / 12;
            final fy = midY + amp * sin(i / 12 * periods * 2 * pi);
            path.lineTo(fx, fy);
          }
          canvas.drawPath(path, paint);
        case ScratchOutStyle.blackOut:
          // 涂黑: 覆盖整块区域的实心色块 (略带不透明度 + 轻微波浪边缘,
          // 更像用笔涂掉的效果)
          final block = Paint()
            ..color = config.scratchOutColor.withValues(alpha: 0.82)
            ..style = PaintingStyle.fill;
          final path = Path();
          final padX = _s * 1.5;
          path.moveTo(s.x - padX, s.y - _s * 0.6);
          path.lineTo(s.x + s.w + padX, s.y - _s * 0.6);
          path.quadraticBezierTo(
              s.x + s.w + padX + _s * 0.8,
              s.y + s.h / 2,
              s.x + s.w + padX,
              s.y + s.h + _s * 0.6);
          path.lineTo(s.x - padX, s.y + s.h + _s * 0.6);
          path.quadraticBezierTo(
              s.x - padX - _s * 0.8, s.y + s.h / 2, s.x - padX, s.y - _s * 0.6);
          path.close();
          canvas.drawPath(path, block);
      }
    }
  }

  void _drawScratchLine(
      Canvas canvas, Paint paint, double x1, double x2, double y) {
    final path = Path();
    path.moveTo(x1, y);
    final midX = (x1 + x2) / 2;
    final midY = y + (_s * (1.2 * ((x2 - x1).abs() > 8 ? 1 : 0)));
    path.quadraticBezierTo(
        midX, midY + _s * 1.5, x2, y + (_s * (0.5 * (_random1(x1) * 2 - 1))));
    canvas.drawPath(path, paint);
  }

  double _random1(double seed) =>
      ((seed * 2654435761) % 1000) / 1000 - 0.5;

  @override
  bool shouldRepaint(covariant _HandwritingPainter oldDelegate) {
    return oldDelegate.config != config ||
        oldDelegate.layout != layout ||
        oldDelegate.fontFamily != fontFamily;
  }
}

// ─────────────────────────── 字体解析 ───────────────────────────

/// 手写字体解析器
///
/// - 内置字体: 已在 pubspec 注册, 直接返回 family 名
/// - 自定义 TTF: 读取文件字节 → FontLoader 注册为 `EwtHwCustom`
/// - 系统字体: 返回平台候选 family (Windows 楷体等)
class HandwritingFontResolver {
  static const _customFamily = 'EwtHwCustom';

  /// 已注册的自定义字体路径缓存
  static String? _loadedCustomPath;
  static Future<void>? _customLoading;

  static Future<String> resolveFamily(HandwritingFontConfig font) async {
    switch (font.source) {
      case HandwritingFontSource.bundled:
        return HandwrittenFontOption.byName(font.bundledName)?.fontFamily ??
            'LXGWWenKai';
      case HandwritingFontSource.system:
        return _systemFamily();
      case HandwritingFontSource.custom:
        await _ensureCustomLoaded(font.customPath);
        return _customFamily;
    }
  }

  static String _systemFamily() {
    if (Platform.isWindows) return '楷体';
    if (Platform.isAndroid) return 'Noto Serif CJK SC';
    return 'LXGWWenKai';
  }

  static Future<void> _ensureCustomLoaded(String path) async {
    if (path.isEmpty) return;
    if (_loadedCustomPath == path) return;
    if (_customLoading != null) {
      await _customLoading;
      if (_loadedCustomPath == path) return;
    }
    final loading = () async {
      try {
        final file = File(path);
        if (!await file.exists()) return;
        final bytes = await file.readAsBytes();
        final loader = FontLoader(_customFamily)
          ..addFont(Future.value(
              ByteData.sublistView(Uint8List.fromList(bytes))));
        await loader.load();
        _loadedCustomPath = path;
      } catch (_) {
        // 加载失败: 回退到内置字体 (family 保持 EwtHwCustom,
        // 引擎会 fallback 到默认字体)
      }
    }();
    _customLoading = loading;
    await loading;
  }
}
