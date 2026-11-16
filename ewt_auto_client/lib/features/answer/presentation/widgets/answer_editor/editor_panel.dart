/// 编辑器面板：内容块模型（文本/图片/公式/涂鸦）与面板 UI，各块可序列化为 HTML 用于提交与回显。
/// showEditorPanel 编辑完成后经 Navigator.pop 返回编辑结果。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'drawing_canvas.dart';
import 'latex_input.dart';

import '../handwritten_page.dart';
import '../../../domain/entities/handwriting_config.dart';
import '../../providers/handwriting_config_provider.dart';

/// 编辑器提交结�?///
/// �?[showEditorPanel] 通过 Navigator.pop 返回�?/// 编辑器内容块类型
enum EditorBlockType {
  text,
  image,
  formula,
  drawing,
}

/// 编辑器内容块抽象
abstract class EditorBlock {
  EditorBlockType get type;

  /// 序列化为 HTML (用于提交 / 回显)
  String toHtml();

  void dispose() {}
}

/// 文本块: 块级排版 (标题级别 + 行内样式 + 对齐 + 列表)
class TextBlock extends EditorBlock {
  final TextEditingController controller;
  int heading; // 0 正文 / 1 H1 / 2 H2 / 3 小字
  bool bold = false;
  bool italic = false;
  bool underline = false;
  bool strike = false;
  Color? color;
  Color? background;
  TextAlign align = TextAlign.left;
  bool ordered = false; // 作为列表项 (有序 / 无序)

  TextBlock({String text = '', this.heading = 0})
      : controller = TextEditingController(text: text);

  @override
  EditorBlockType get type => EditorBlockType.text;

  @override
  void dispose() => controller.dispose();

  @override
  String toHtml() {
    final text = controller.text;
    if (text.trim().isEmpty) return '';
    final styles = <String>[];
    if (color != null) styles.add('color:${color!.hex}');
    if (background != null) styles.add('background-color:${background!.hex}');
    if (align != TextAlign.left) {
      styles.add('text-align:${align == TextAlign.center
          ? 'center'
          : align == TextAlign.right
              ? 'right'
              : 'left'}');
    }
    final styleAttr = styles.isNotEmpty ? ' style="${styles.join(';')}"' : '';
    final inner = _escape(text);
    final decorated = _decorate(inner);

    if (heading == 1) return '<h1$styleAttr>$decorated</h1>';
    if (heading == 2) return '<h2$styleAttr>$decorated</h2>';
    if (heading == 3) {
      return '<p$styleAttr style="font-size:12px">$decorated</p>';
    }
    if (ordered) return '<li$styleAttr>$decorated</li>';
    return '<p$styleAttr>$decorated</p>';
  }

  String _decorate(String inner) {
    var s = inner;
    if (bold) s = '<b>$s</b>';
    if (italic) s = '<i>$s</i>';
    if (underline) s = '<u>$s</u>';
    if (strike) s = '<s>$s</s>';
    return s;
  }

  static String _escape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

/// 图片块 (本地上传图片, 支持宽度比例)
class ImageBlock extends EditorBlock {
  final Uint8List bytes;
  final String name;
  double widthFactor; // 0.2 ~ 1.0 占编辑器宽度比例

  ImageBlock(this.bytes, this.name, {this.widthFactor = 0.6});

  @override
  EditorBlockType get type => EditorBlockType.image;

  @override
  String toHtml() {
    final b64 = base64Encode(bytes);
    final pct = (widthFactor * 100).toInt();
    return '<img src="data:image/png;base64,$b64" '
        'style="width:${pct}%;max-width:100%" alt="$name"/>';
  }
}

/// 公式块 (LaTeX)
class FormulaBlock extends EditorBlock {
  final String latex;

  FormulaBlock(this.latex);

  @override
  EditorBlockType get type => EditorBlockType.formula;

  @override
  String toHtml() => '<p style="text-align:center">'
      '\$\$${latex.replaceAll('&', '&amp;').replaceAll('<', '&lt;')}\$\$</p>';
}

/// 涂鸦块 (以 PNG 字节承载, 复用图片渲染)
class DrawingBlock extends EditorBlock {
  final Uint8List bytes;
  final String name;

  DrawingBlock(this.bytes, {this.name = 'drawing.png'});

  @override
  EditorBlockType get type => EditorBlockType.drawing;

  @override
  String toHtml() {
    final b64 = base64Encode(bytes);
    return '<img src="data:image/png;base64,$b64" '
        'style="width:100%;max-width:100%" alt="$name"/>';
  }
}

/// 颜色 <-> #RRGGBB 工具
extension ColorHex on Color {
  String get hex {
    final a = (this.a * 255).toInt().toRadixString(16).padLeft(2, '0');
    final r = (this.r * 255).toInt().toRadixString(16).padLeft(2, '0');
    final g = (this.g * 255).toInt().toRadixString(16).padLeft(2, '0');
    final b = (this.b * 255).toInt().toRadixString(16).padLeft(2, '0');
    return '#$r$g$b$a'.toUpperCase();
  }
}

Color? parseHex(String? s) {
  if (s == null) return null;
  final v = s.trim().replaceAll('#', '');
  if (v.length < 6) return null;
  final r = int.parse(v.substring(0, 2), radix: 16);
  final g = int.parse(v.substring(2, 4), radix: 16);
  final b = int.parse(v.substring(4, 6), radix: 16);
  return Color.fromRGBO(r, g, b, 1);
}

// ─── HTML ↔ EditorBlock 互转 (草稿恢复, 保证保存/重载幂等) ───

/// 将编辑器序列化出的 HTML 还原为编辑器内容块.
///
/// 关键: 重载时把 HTML 解析回内容块, 而非当作纯文本塞回文本框,
/// 否则下次保存会再次转义, 导致内容反复嵌套 (`<p>&lt;p&gt;...&lt;/p&gt;</p>`).
List<EditorBlock> parseHtmlToBlocks(String html) {
  final blocks = <EditorBlock>[];
  if (html.trim().isEmpty) return blocks;

  final blockPattern = RegExp(
    r'<(p|h1|h2|li)\b([^>]*)>(.*?)</\1>|<img\b([^>]*)/?>',
    caseSensitive: false,
    dotAll: true,
  );
  final matches = blockPattern.allMatches(html);

  if (matches.isEmpty) {
    final text = _stripAllTags(html);
    if (text.trim().isNotEmpty) blocks.add(TextBlock(text: text));
    return blocks;
  }

  for (final m in matches) {
    if (m.group(1) != null) {
      blocks.add(_parseTextLikeBlock(
        m.group(1)!.toLowerCase(),
        m.group(2) ?? '',
        m.group(3) ?? '',
      ));
    } else if (m.group(4) != null) {
      final img = _parseImageTag(m.group(4)!);
      if (img != null) blocks.add(img);
    }
  }
  return blocks;
}

EditorBlock _parseTextLikeBlock(String tag, String attrs, String inner) {
  // 公式块: <p style="text-align:center">$$latex$$</p>
  final formula = RegExp(r'^\s*\$\$(.*)\$\$\s*$', dotAll: true).firstMatch(inner);
  if (formula != null) {
    return FormulaBlock(_unescapeHtml(formula.group(1)!));
  }

  final block = TextBlock();
  if (tag == 'h1') block.heading = 1;
  if (tag == 'h2') block.heading = 2;
  if (tag == 'li') block.ordered = true;
  if (tag == 'p' && attrs.contains('font-size:12px')) block.heading = 3;

  // 行内装饰 (块级: 整块统一)
  block.bold = inner.contains(RegExp(r'<b>', caseSensitive: false));
  block.italic = inner.contains(RegExp(r'<i>', caseSensitive: false));
  block.underline = inner.contains(RegExp(r'<u>', caseSensitive: false));
  block.strike = inner.contains(RegExp(r'<s>', caseSensitive: false));

  var text =
      inner.replaceAll(RegExp(r'</?(b|i|u|s)>', caseSensitive: false), '');

  // 样式: 对齐 / 颜色 / 背景
  final style = _attrValue(attrs, 'style') ?? '';
  if (style.contains('text-align:center')) block.align = TextAlign.center;
  if (style.contains('text-align:right')) block.align = TextAlign.right;
  final color = _styleValue(style, 'color');
  if (color != null) block.color = parseHex(color);
  final bg = _styleValue(style, 'background-color');
  if (bg != null) block.background = parseHex(bg);

  block.controller.text = _unescapeHtml(text);
  return block;
}

EditorBlock? _parseImageTag(String attrs) {
  final src = _attrValue(attrs, 'src');
  if (src == null || !src.startsWith('data:image')) return null;
  final comma = src.indexOf(',');
  if (comma < 0) return null;
  final meta = src.substring(5, comma).toLowerCase();
  final payload = src.substring(comma + 1);
  Uint8List bytes;
  try {
    bytes = meta.contains(';base64')
        ? base64Decode(payload)
        : Uint8List.fromList(utf8.encode(Uri.decodeComponent(payload)));
  } catch (_) {
    return null;
  }
  if (bytes.isEmpty) return null;
  final name = _attrValue(attrs, 'alt') ?? 'img.png';
  final style = _attrValue(attrs, 'style') ?? '';
  final pctMatch = RegExp(r'width:(\d+)%').firstMatch(style);
  var widthFactor = 0.6;
  if (pctMatch != null) {
    final pct = (int.tryParse(pctMatch.group(1)!) ?? 60).clamp(20, 100);
    widthFactor = pct / 100.0;
  }
  return ImageBlock(bytes, name, widthFactor: widthFactor);
}

String? _attrValue(String tag, String name) {
  final m = RegExp('$name="([^"]*)"').firstMatch(tag);
  return m?.group(1);
}

String? _styleValue(String style, String prop) {
  final m = RegExp('$prop:\\s*(#[0-9A-Fa-f]{3,8})').firstMatch(style);
  return m?.group(1);
}

String _stripAllTags(String html) =>
    html.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll('&nbsp;', ' ');

String _unescapeHtml(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ');

class EditorResult {
  final String html;
  final List<Uint8List> images;
  final List<String> imageNames;
  final bool submit;

  const EditorResult({
    required this.html,
    required this.images,
    required this.imageNames,
    this.submit = false,
  });
}

/// 打开右侧滑出式编辑器
///
/// [initialHtml] / [initialImages] 用于草稿恢复�?
Future<EditorResult?> showEditorPanel(
  BuildContext context, {
  String? initialHtml,
  List<Uint8List>? initialImages,
  List<String>? initialImageNames,
  bool submitOnComplete = false,
}) {
  return Navigator.of(context).push<EditorResult>(
    PageRouteBuilder(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, __, ___) => EditorPanelPage(
        initialHtml: initialHtml,
        initialImages: initialImages,
        initialImageNames: initialImageNames,
      ),
      transitionsBuilder: (_, anim, __, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        child: child,
      ),
    ),
  );
}

class EditorPanelPage extends ConsumerStatefulWidget {
  final String? initialHtml;
  final List<Uint8List>? initialImages;
  final List<String>? initialImageNames;

  const EditorPanelPage({
    super.key,
    this.initialHtml,
    this.initialImages,
    this.initialImageNames,
  });

  @override
  ConsumerState<EditorPanelPage> createState() => _EditorPanelPageState();
}

class _EditorPanelPageState extends ConsumerState<EditorPanelPage> {
  final List<EditorBlock> _blocks = [];
  TextBlock? _active;
  final Map<TextBlock, FocusNode> _focus = {};
  double _dragDx = 0;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 草稿恢复: 解析 HTML 暂以单文本块承载; 图片作为图片块恢�?    
    final parsed = <EditorBlock>[];
    if (widget.initialHtml != null && widget.initialHtml!.trim().isNotEmpty) {
      parsed.addAll(parseHtmlToBlocks(widget.initialHtml!));
    }
    _blocks.addAll(parsed);
    final imgs = widget.initialImages ?? [];
    final names = widget.initialImageNames ?? [];
    for (int i = 0; i < imgs.length; i++) {
      _blocks.add(ImageBlock(imgs[i], i < names.length ? names[i] : 'img$i.png'));
    }
    if (_blocks.isEmpty) {
      _addText('', focus: true);
    } else {
      TextBlock? firstText;
      for (final b in parsed) {
        if (b is TextBlock) {
          firstText = b;
          break;
        }
      }
      if (firstText != null) _active = firstText;
    }
  }

  TextBlock _addText(String text, {bool focus = true}) {
    final b = TextBlock(text: text);
    _focus[b] = FocusNode()
      ..addListener(() {
        if (_focus[b]!.hasFocus) setState(() => _active = b);
      });
    _blocks.add(b);
    if (focus) WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus[b]?.requestFocus();
      setState(() => _active = b);
    });
    return b;
  }

  FocusNode _focusOf(TextBlock b) => _focus.putIfAbsent(b, () {
        final n = FocusNode();
        n.addListener(() {
          if (n.hasFocus) setState(() => _active = b);
        });
        return n;
      });

  void _apply(void Function(TextBlock) f) {
    if (_active == null) {
      final b = _addText('');
      f(b);
      return;
    }
    setState(() => f(_active!));
  }

  Future<void> _insertImage() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (r == null || r.files.isEmpty) return;
    final b = r.files.first.bytes;
    if (b == null) return;
    setState(() => _blocks.add(ImageBlock(b, r.files.first.name)));
  }

  Future<void> _insertFormula() async {
    final latex = await showFormulaDialog(context);
    if (latex == null || latex.isEmpty) return;
    setState(() => _blocks.add(FormulaBlock(latex)));
  }

  Future<void> _insertDrawing() async {
    final bytes = await Navigator.of(context).push<Uint8List?>(
      MaterialPageRoute(builder: (_) => const _DrawingScreen()),
    );
    if (bytes == null) return;
    setState(() => _blocks.add(DrawingBlock(bytes)));
  }

  void _removeBlock(EditorBlock b) {
    setState(() {
      _blocks.remove(b);
      if (b is TextBlock) _focus[b]?.dispose();
    });
  }

  EditorResult _buildResult({bool submit = false}) {
    final html = _blocks.map((b) => b.toHtml()).join('\n');
    final images = <Uint8List>[];
    final names = <String>[];
    for (final b in _blocks) {
      if (b is ImageBlock) {
        images.add(b.bytes);
        names.add(b.name);
      } else if (b is DrawingBlock) {
        images.add(b.bytes);
        names.add(b.name);
      }
    }
    return EditorResult(html: html, images: images, imageNames: names, submit: submit);
  }

  void _close([bool submit = false]) =>
      Navigator.of(context).pop(_buildResult(submit: submit));

  /// 手写模拟预览: 用持久化的手写配置把当前编辑器内容渲染成手写效果,
  /// 不改变提交流程.
  Future<void> _previewHandwriting() async {
    final result = _buildResult();
    if (result.html.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先输入内容再预览手写效果')),
        );
      }
      return;
    }
    final config = ref.read(handwritingConfigProvider);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _HandwritingPreviewDialog(
        html: result.html,
        config: config,
      ),
    );
  }

  @override
  void dispose() {
    for (final n in _focus.values) n.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 720;

    Widget panel = Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            // 头部
            _buildHeader(theme, isDesktop),
            const Divider(height: 1),
            // toolbar
            _buildToolbar(theme),
            const Divider(height: 1),
            // content
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                itemCount: _blocks.length,
                itemBuilder: (_, i) => _buildBlock(theme, _blocks[i]),
              ),
            ),
            // 底部
            _buildFooter(theme),
          ],
        ),
      ),
    );

    if (!isDesktop) {
      // 移动�? 支持右滑关闭
      panel = GestureDetector(
        onPanUpdate: (d) {
          if (d.delta.dx > 0 || _dragDx > 0) {
            setState(() => _dragDx += d.delta.dx);
          }
        },
        onPanEnd: (_) {
          if (_dragDx > 100) {
            _close();
          } else {
            setState(() => _dragDx = 0);
          }
        },
        child: Transform.translate(
          offset: Offset(_dragDx, 0),
          child: panel,
        ),
      );
    }

    if (isDesktop) {
      // 桌面�? 左侧遮罩, 点击关闭
      return Scaffold(
        backgroundColor: Colors.black54,
        body: Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => _close(),
                child: Container(color: Colors.transparent),
              ),
            ),
            SizedBox(
              width: MediaQuery.of(context).size.width * 0.65,
              child: panel,
            ),
          ],
        ),
      );
    }
    return Scaffold(body: panel);
  }

  Widget _buildHeader(ThemeData theme, bool isDesktop) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          if (!isDesktop)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '关闭',
              onPressed: () => _close(),
            ),
          Expanded(
            child: Text(
              'Editor',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('保存草稿'),
            onPressed: () => _close(),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    final a = _active;
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // 标题级别
          _Chip(
            selected: a?.heading == 1,
            label: 'H1',
            onTap: () => _apply((b) => b.heading = b.heading == 1 ? 0 : 1),
          ),
          _Chip(
            selected: a?.heading == 2,
            label: 'H2',
            onTap: () => _apply((b) => b.heading = b.heading == 2 ? 0 : 2),
          ),
          _Chip(
            selected: a?.heading == 3,
            label: '小字',
            onTap: () => _apply((b) => b.heading = b.heading == 3 ? 0 : 3),
          ),
          const VerticalDivider(),
          _IconBtn(
            icon: Icons.format_bold,
            selected: a?.bold ?? false,
            onTap: () => _apply((b) => b.bold = !b.bold),
          ),
          _IconBtn(
            icon: Icons.format_italic,
            selected: a?.italic ?? false,
            onTap: () => _apply((b) => b.italic = !b.italic),
          ),
          _IconBtn(
            icon: Icons.format_underlined,
            selected: a?.underline ?? false,
            onTap: () => _apply((b) => b.underline = !b.underline),
          ),
          _IconBtn(
            icon: Icons.format_strikethrough,
            selected: a?.strike ?? false,
            onTap: () => _apply((b) => b.strike = !b.strike),
          ),
          const VerticalDivider(),
          _IconBtn(
            icon: Icons.format_align_left,
            selected: a?.align == TextAlign.left,
            onTap: () => _apply((b) => b.align = TextAlign.left),
          ),
          _IconBtn(
            icon: Icons.format_align_center,
            selected: a?.align == TextAlign.center,
            onTap: () => _apply((b) => b.align = TextAlign.center),
          ),
          _IconBtn(
            icon: Icons.format_align_right,
            selected: a?.align == TextAlign.right,
            onTap: () => _apply((b) => b.align = TextAlign.right),
          ),
          const VerticalDivider(),
          _IconBtn(
            icon: Icons.format_list_bulleted,
            selected: a?.ordered ?? false,
            onTap: () => _apply((b) => b.ordered = !b.ordered),
          ),
          // 颜色
          _ColorBtn(
            label: '字色',
            color: a?.color,
            onPicked: (c) => _apply((b) => b.color = c),
          ),
          _ColorBtn(
            label: '高亮',
            color: a?.background,
            onPicked: (c) => _apply((b) => b.background = c),
          ),
          const VerticalDivider(),
          // 插入
          _Chip(label: '图片', icon: Icons.image, onTap: _insertImage),
          _Chip(label: '公式', icon: Icons.functions, onTap: _insertFormula),
          _Chip(label: '涂鸦', icon: Icons.brush, onTap: _insertDrawing),
          _Chip(
            label: '文本',
            icon: Icons.text_fields,
            onTap: () => _addText(''),
          ),
          const VerticalDivider(),
          _Chip(
            label: '手写模拟',
            icon: Icons.brush_outlined,
            onTap: _previewHandwriting,
          ),
        ],
      ),
    );
  }

  Widget _buildBlock(ThemeData theme, EditorBlock b) {
    if (b is TextBlock) {
      final align = b.align == TextAlign.center
          ? TextAlign.center
          : b.align == TextAlign.right
              ? TextAlign.right
              : TextAlign.left;
      final size = b.heading == 1
          ? 24.0
          : b.heading == 2
              ? 20.0
              : b.heading == 3
                  ? 12.0
                  : 16.0;
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  focusNode: _focusOf(b),
                  controller: b.controller,
                  onChanged: (_) => setState(() {}),
                  textAlign: align,
                  style: TextStyle(
                    fontSize: size,
                    fontWeight: b.bold ? FontWeight.bold : FontWeight.normal,
                    fontStyle: b.italic ? FontStyle.italic : FontStyle.normal,
                    decoration: TextDecoration.combine([
                      if (b.underline) TextDecoration.underline,
                      if (b.strike) TextDecoration.lineThrough,
                    ]),
                    color: b.color,
                    backgroundColor: b.background,
                  ),
                  maxLines: null,
                  decoration: const InputDecoration.collapsed(
                    hintText: 'Enter',
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () => _removeBlock(b),
              ),
            ],
          ),
        ),
      );
    }
    if (b is ImageBlock) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Image.memory(b.bytes),
              Row(
                children: [
                  const Text('宽度', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      min: 0.2,
                      max: 1.0,
                      value: b.widthFactor,
                      onChanged: (v) => setState(() => b.widthFactor = v),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _removeBlock(b),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    // 公式 / 涂鸦�?    
return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: b is FormulaBlock
                  ? Text('公式: ${b.latex}', style: const TextStyle(fontSize: 14))
                  : Text('Doodle', style: TextStyle(fontSize: 14)),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () => _removeBlock(b),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _close(),
                child: const Text('关闭'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.check, size: 18),
                label: const Text('提交'),
                onPressed: () => _close(true),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 涂鸦全屏编辑�?
class _DrawingScreen extends StatelessWidget {
  const _DrawingScreen();

  @override
  Widget build(BuildContext context) {
    final key = GlobalKey<DrawingCanvasState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('涂鸦作答'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '完成',
            onPressed: () async {
              final bytes = await key.currentState?.exportPng();
              if (context.mounted) Navigator.pop(context, bytes);
            },
          ),
        ],
      ),
      body: DrawingCanvas(key: key),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, this.icon, this.selected = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: selected ? theme.colorScheme.primaryContainer : null,
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.dividerColor,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 16),
            if (icon != null) const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _IconBtn(
      {required this.icon, this.selected = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      icon: Icon(icon, size: 18),
      isSelected: selected,
      selectedIcon: Icon(icon, size: 18, color: theme.colorScheme.primary),
      style: IconButton.styleFrom(
        backgroundColor:
            selected ? theme.colorScheme.primaryContainer : null,
        padding: const EdgeInsets.all(6),
        minimumSize: const Size(32, 32),
      ),
      onPressed: onTap,
    );
  }
}

class _ColorBtn extends StatelessWidget {
  final String label;
  final Color? color;
  final ValueChanged<Color?> onPicked;
  const _ColorBtn(
      {required this.label, this.color, required this.onPicked});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Color?>(
      tooltip: label,
      itemBuilder: (_) => [
        PopupMenuItem(
          value: null,
          child: const Text('清除'),
        ),
        ...DrawingCanvasState.palette.map(
          (c) => PopupMenuItem(value: c, child: _Swatch(c)),
        ),
        PopupMenuItem(
          value: Colors.transparent,
          child: _CustomColor(onPicked: onPicked),
        ),
      ],
      onSelected: (c) {
        if (c != Colors.transparent) onPicked(c);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: color ?? Colors.transparent,
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color c;
  const _Swatch(this.c);
  @override
  Widget build(BuildContext context) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: c,
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(4),
        ),
      );
}

class _CustomColor extends StatefulWidget {
  final ValueChanged<Color?> onPicked;
  const _CustomColor({required this.onPicked});
  @override
  State<_CustomColor> createState() => _CustomColorState();
}

class _CustomColorState extends State<_CustomColor> {
  final TextEditingController _c = TextEditingController();
  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Text('自定�?#'),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _c,
              decoration: const InputDecoration(isDense: true),
              onSubmitted: (v) {
                final col = parseHex(v);
                if (col != null) {
                  widget.onPicked(col);
                  Navigator.pop(context);
                }
              },
            ),
          ),
        ],
      );
}

/// 手写模拟预览弹窗: 用指定配置把编辑器内容渲染成手写效果.
class _HandwritingPreviewDialog extends StatelessWidget {
  final String html;
  final HandwritingConfig config;

  const _HandwritingPreviewDialog({
    required this.html,
    required this.config,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final double width =
        (MediaQuery.of(context).size.width - 48).clamp(320.0, 1000.0);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Text('手写模拟预览', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: SizedBox(
                  width: width,
                  child: HandwrittenPage(
                    html: html,
                    config: config,
                    width: width,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

