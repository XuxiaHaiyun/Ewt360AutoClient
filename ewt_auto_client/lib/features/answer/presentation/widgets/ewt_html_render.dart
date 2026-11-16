/// EWT 平台 HTML 渲染公共工具，提供答案展示与图片生成共用的 flutter_html 扩展与样式。
/// 关键约束：file.ewt360.com 的 SVG 公式与位图混在同一 CDN，按扩展名自适应渲染并需携带 EWT Referer headers。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart' as vg;

import '../../../../core/network/api_helper.dart';

/// EWT 平台 HTML 渲染公共工具
///
/// 提供"展示答案"与"图片生成"两条路径共用的渲染扩展:
/// - [buildEwtHtmlExtensions]: flutter_html 的 `<img>` 扩展,
///   自适应 SVG (数学公式 Wirisformula) / 位图 (PNG/JPG 题干配图)。
/// - [ewtHtmlStyle]: flutter_html 样式 (公式图片垂直居中, MathML 容器等)。
///
/// 关键 (通过 reqable 分析 HAR 发现):
/// - file.ewt360.com 既返回 **SVG** (数学公式 Wirisformula / 部分题干图),
///   也返回 **位图** (PNG/JPG 题干配图)。二者混在同一 CDN, 不能简单按域名判断。
/// - Flutter 的 Image.network 不支持 SVG, 必须用 SvgPicture.network
/// - answer/paper 接口的 Origin/Referer = web.ewt360.com (而非 teacher.ewt360.com)
/// - file.ewt360.com CDN 图片需要匹配的 Referer 才能加载
/// - 图片 URL 可能是 http:// (Flutter 默认阻止) → 应转为 https
///
/// 修复 (_EwtNetworkImage):
/// 1. 按扩展名优先判定 SVG / 位图, 不再把 file.ewt360.com 全部当 SVG
///    (位图被当 SVG 解析会抛 XmlParserException)。
/// 2. SvgPicture.network 增加 errorBuilder: 失败时回退位图加载, 且任一路径都有
///    errorBuilder, 失败显示"[图片]"占位, 不再无限转圈。

/// EWT CDN 图片加载所需的 HTTP headers
Map<String, String> get ewtCdnHeaders => <String, String>{
      ...ApiHeaders.web,
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36',
      'Accept':
          'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
    };

/// flutter_html 样式 (与答案展示页一致)
Map<String, Style> ewtHtmlStyle(ThemeData theme) {
  return {
    'body': Style(margin: Margins.zero, padding: HtmlPaddings.zero),
    'p': Style(margin: Margins.symmetric(vertical: 2)),
    // 公式图片: 垂直居中, 避免基线偏移导致空白
    'img': Style(
      margin: Margins.symmetric(horizontal: 1),
      verticalAlign: VerticalAlign.middle,
    ),
    // MathML 容器
    'math': Style(
      margin: Margins.symmetric(horizontal: 2),
      verticalAlign: VerticalAlign.middle,
    ),
  };
}

/// EWT 平台图片/公式渲染扩展
///
/// 返回 flutter_html 的 `extensions` 参数, 自适应处理 `<img>` 标签:
/// SVG 用 [SvgPicture.string] 渲染, 位图用 [Image.memory] 渲染,
/// 任何失败路径都以"[图片]"占位结束, 绝不无限转圈、绝不抛未捕获异常。
List<HtmlExtension> buildEwtHtmlExtensions() {
  return [
    TagExtension(
      tagsToExtend: {'img'},
      builder: (extensionContext) {
        var src = extensionContext.attributes['src'] ?? '';
        if (src.isEmpty) return const SizedBox.shrink();

        // 兜底: 确保转为 https
        if (src.startsWith('//')) {
          src = 'https:$src';
        } else if (src.startsWith('http://')) {
          src = 'https://${src.substring(7)}';
        }

        final uri = Uri.tryParse(src);
        if (uri == null || !uri.hasScheme) {
          return const SizedBox.shrink();
        }

        // 自适应 SVG / 位图, 失败时回退, 不会无限转圈
        return EwtNetworkImage(src: src, headers: ewtCdnHeaders);
      },
    ),
  ];
}

/// 下载并解析 EWT 图片 (SVG 公式 / 位图), 供 [EwtNetworkImage] 与
/// 手写模拟渲染 ([HandwrittenPage]) 共用。
///
/// 任何失败路径都返回 [EwtImageData.error], 绝不抛未捕获异常。
Future<EwtImageData> loadEwtImageData(
  String src, {
  Map<String, String> headers = const {},
}) async {
  try {
    late final Uint8List bytes;
    if (src.startsWith('data:')) {
      final decoded = _decodeDataUri(src);
      if (decoded == null || decoded.isEmpty) {
        return const EwtImageData.error();
      }
      bytes = decoded;
    } else {
      final d = await _download(src, headers);
      if (d == null || d.isEmpty) return const EwtImageData.error();
      bytes = d;
    }

    if (_looksLikeSvg(bytes)) {
      final text = utf8.decode(bytes, allowMalformed: true);
      // 1) 原文预校验 —— 与 SvgPicture.string 使用同一个 SvgParser,
      //    这里通过则渲染必定不会抛 XmlParserException
      if (_validateSvg(text)) return EwtImageData.svg(text);
      // 2) 修复常见畸形: 属性/文本中未转义的 & (Wiris 公式常见) 后重试
      final fixed = _sanitizeSvg(text);
      if (fixed != text && _validateSvg(fixed)) {
        return EwtImageData.svg(fixed);
      }
      return const EwtImageData.error();
    }
    // 非 SVG: 交给 Image.memory (PNG/JPG/GIF/WebP/BMP 均支持)
    return EwtImageData.raster(bytes);
  } catch (_) {
    return const EwtImageData.error();
  }
}

/// 解析 data: URI (data:[mime][;base64],<payload>) 为字节.
/// 不支持或非法时返回 null.
Uint8List? _decodeDataUri(String src) {
  try {
    final comma = src.indexOf(',');
    if (comma < 0) return null;
    final meta = src.substring(5, comma).toLowerCase();
    final payload = src.substring(comma + 1);
    if (meta.contains(';base64')) {
      return base64Decode(payload);
    }
    return Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
  } catch (_) {
    return null;
  }
}

/// 用 HttpClient 下载图片字节, 带 EWT CDN 所需 headers
Future<Uint8List?> _download(
    String src, Map<String, String> headers) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(src));
    headers.forEach(req.headers.set);
    final resp = await req.close().timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

/// 按内容判断是否 SVG: 跳过 BOM/空白后以 '<' 开头且含 "<svg"
bool _looksLikeSvg(Uint8List bytes) {
  // PNG/JPEG/GIF/WebP/BMP 魔数直接排除
  if (bytes.length >= 4) {
    if (bytes[0] == 0x89 && bytes[1] == 0x50) return false; // PNG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return false; // JPEG
    if (bytes[0] == 0x47 && bytes[1] == 0x49) return false; // GIF
    if (bytes[0] == 0x52 && bytes[1] == 0x49) return false; // RIFF/WebP
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return false; // BMP
  }
  final head = utf8
      .decode(bytes.sublist(0, bytes.length < 512 ? bytes.length : 512),
          allowMalformed: true)
      .trimLeft();
  return head.startsWith('<') && head.toLowerCase().contains('<svg');
}

/// 同步预校验 SVG —— 与 flutter_svg 渲染共用同一个解析器,
/// 在 try/catch 内吞掉 XmlParserException 等一切解析错误
bool _validateSvg(String text) {
  try {
    vg.parseWithoutOptimizers(text);
    return true;
  } catch (_) {
    return false;
  }
}

/// 修复常见 SVG 畸形: 未转义的裸 & → &amp;
String _sanitizeSvg(String text) {
  return text.replaceAllMapped(
    RegExp(r'&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)'),
    (_) => '&amp;',
  );
}

/// 自适应网络图片。
///
/// 实现策略 (v2, 修复 Unhandled XmlParserException):
/// - 不再使用 SvgPicture.network: flutter_svg 的网络加载在异步解码管线中
///   解析 SVG, EWT 返回的畸形 SVG (Wirisformula) 抛出的 XmlParserException
///   发生在 errorBuilder 覆盖不到的 Future 链里 → Unhandled Exception。
/// - 改为: 自行下载字节 → 按内容(魔数)判断真实类型 → SVG 先用
///   vector_graphics_compiler.parse 在 try/catch 中**同步预校验**
///   (与 SvgPicture.string 完全同一个 SvgParser), 校验通过才交给
///   SvgPicture.string 渲染; 失败先尝试修复常见畸形(未转义的 &),
///   仍失败显示占位。位图用 Image.memory。
/// - 结果按 URL 静态缓存, 避免列表滚动反复下载/解析。
///
/// 任何失败路径都以"[图片]"占位结束, 绝不无限转圈、绝不抛未捕获异常。
class EwtNetworkImage extends StatefulWidget {
  final String src;
  final Map<String, String> headers;

  const EwtNetworkImage({super.key, required this.src, required this.headers});

  @override
  State<EwtNetworkImage> createState() => _EwtNetworkImageState();
}

/// 下载 + 类型判定 + SVG 预校验的结果
class EwtImageData {
  final Uint8List? rasterBytes; // 位图字节 (非空表示按位图渲染)
  final String? svgText; // 已通过预校验的 SVG 文本
  final bool failed; // 下载失败或 SVG 无法解析且非位图

  const EwtImageData.raster(Uint8List this.rasterBytes)
      : svgText = null,
        failed = false;
  const EwtImageData.svg(String this.svgText)
      : rasterBytes = null,
        failed = false;
  const EwtImageData.error()
      : rasterBytes = null,
        svgText = null,
        failed = true;
}

class _EwtNetworkImageState extends State<EwtNetworkImage> {
  /// URL → 加载结果缓存 (公式在同一页面大量复用, 避免重复下载/解析)
  static final Map<String, Future<EwtImageData>> _cache = {};

  late final Future<EwtImageData> _future;

  @override
  void initState() {
    super.initState();
    _future = _cache.putIfAbsent(
        widget.src, () => loadEwtImageData(widget.src, headers: widget.headers));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<EwtImageData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _spinner(context);
        }
        final data = snapshot.data;
        if (data == null || data.failed) return _brokenImage();
        if (data.svgText != null) {
          return SvgPicture.string(
            data.svgText!,
            fit: BoxFit.contain,
            // 双保险: 预校验已保证可解析, 但仍保留 errorBuilder
            errorBuilder: (context, error, stackTrace) => _brokenImage(),
          );
        }
        return Image.memory(
          data.rasterBytes!,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _brokenImage(),
        );
      },
    );
  }

  Widget _spinner(BuildContext context) => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(Colors.grey.shade400),
        ),
      );

  Widget _brokenImage() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: Colors.orange.shade200, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined,
                size: 12, color: Colors.orange.shade700),
            const SizedBox(width: 2),
            Text(
              '[图片]',
              style: TextStyle(fontSize: 10, color: Colors.orange.shade700),
            ),
          ],
        ),
      );
}
