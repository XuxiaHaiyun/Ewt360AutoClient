/// 编辑器画布背景 widget 构建工具，支持纯色/自定义颜色/自定义图片/手写模拟同款纸张四种背景。
/// 手写纸张复用手写模拟的纸张绘制逻辑（空白/横线/方格/田字格，线距线色可调）。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_math_fork/flutter_math.dart';

import '../../answer/domain/entities/handwriting_config.dart';
import '../domain/entities/editor_config.dart';

/// 构建编辑器画布背�?widget
///
/// 支持四种背景:
/// - [EditorBackgroundType.solid]/[EditorBackgroundType.customColor]: 纯色
/// - [EditorBackgroundType.customImage]: 自定义图片平�?/// - [EditorBackgroundType.handwritingPaper]: 手写模拟同款纸张
///   (空白/横线/方格/田字�? 复用手写模拟纸张绘制逻辑)
Widget buildEditorBackgroundWidget(
  EditorBackground bg,
  double width,
  double height,
) {
  switch (bg.type) {
    case EditorBackgroundType.solid:
    case EditorBackgroundType.customColor:
      return Container(width: width, height: height, color: bg.color);
    case EditorBackgroundType.customImage:
      if (bg.imageBytes != null) {
        return Image.memory(
          bg.imageBytes!,
          width: width,
          height: height,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              Container(width: width, height: height, color: bg.color),
        );
      }
      return Container(width: width, height: height, color: bg.color);
    case EditorBackgroundType.handwritingPaper:
      return CustomPaint(
        size: Size(width, height),
        painter: _PaperPainter(
          paperType: bg.paperType,
          paperColor: bg.paperColor,
          paperLineColor: bg.paperLineColor,
          paperLineSpacing: bg.paperLineSpacing,
        ),
      );
  }
}

/// 手写模拟同款纸张绘制 (复刻 HandwrittenPage._paintPaper 的线条逻辑)
class _PaperPainter extends CustomPainter {
  final HandwritingPaperType paperType;
  final Color paperColor;
  final Color paperLineColor;
  final double paperLineSpacing;

  const _PaperPainter({
    required this.paperType,
    required this.paperColor,
    required this.paperLineColor,
    required this.paperLineSpacing,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = paperColor;
    canvas.drawRect(Offset.zero & size, bg);

    final line = Paint()
      ..color = paperLineColor.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    final light = Paint()
      ..color = paperLineColor.withValues(alpha: 0.3)
      ..strokeWidth = 0.7;
    final spacing = paperLineSpacing;
    const margin = 0.0;

    switch (paperType) {
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
        for (double y = margin; y < size.height; y += spacing) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
          for (double x = margin; x < size.width; x += spacing) {
            final x2 = (x + spacing).clamp(0.0, size.width).toDouble();
            final y2 = (y + spacing).clamp(0.0, size.height).toDouble();
            canvas.drawLine(Offset(x, y), Offset(x2, y2), light);
            canvas.drawLine(Offset(x2, y), Offset(x, y2), light);
          }
        }
        for (double x = margin; x < size.width; x += spacing) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
        }
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _PaperPainter old) =>
      old.paperType != paperType ||
      old.paperColor != paperColor ||
      old.paperLineColor != paperLineColor ||
      old.paperLineSpacing != paperLineSpacing;
}

/// 涂鸦画布背景 widget (涂鸦编辑器内嵌, 支持与编辑器相同的四种背景)
///
/// 与 [buildEditorBackgroundWidget] 一致, 单独导出便于涂鸦编辑器复用。
Widget buildDoodleBackgroundWidget(
  EditorBackground bg,
  double width,
  double height,
) =>
    buildEditorBackgroundWidget(bg, width, height);

/// �?[EditorComponent] 渲染为不可交互的 widget (供导�?预览复用)
Widget buildComponentWidget(EditorComponent c) {
  switch (c.type) {
    case EditorComponentType.text:
      return Container(
        width: c.width,
        height: c.height,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.all(4),
        child: Text(
          c.text ?? '',
          style: TextStyle(
            fontSize: c.textFontSize ?? 24,
            color: c.textColorArgb != null
                ? Color(c.textColorArgb!)
                : Colors.black,
          ),
          softWrap: true,
          overflow: TextOverflow.visible,
        ),
      );
    case EditorComponentType.image:
      if (c.imageBytes != null) {
        return Image.memory(
          c.imageBytes!,
          width: c.width,
          height: c.height,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const Placeholder(),
        );
      }
      return const Placeholder();
    case EditorComponentType.formula:
      return SizedBox(
        width: c.width,
        height: c.height,
        child: _FormulaView(
          latex: c.latex ?? '',
          fontSize: c.formulaFontSize ?? 24,
          color: c.formulaColorArgb != null
              ? Color(c.formulaColorArgb!)
              : Colors.black,
        ),
      );
    case EditorComponentType.doodle:
      return _DoodleView(component: c);
  }
}

/// 公式渲染 (flutter_math_fork)
class _FormulaView extends StatelessWidget {
  final String latex;
  final double fontSize;
  final Color color;
  const _FormulaView({
    required this.latex,
    required this.fontSize,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (latex.trim().isEmpty) {
      return const Center(child: Text('公式为空'));
    }
    final child = Builder(
      builder: (_) {
        try {
          return Math.tex(
            latex,
            mathStyle: MathStyle.text,
            // 显式指定颜色: 不继承环境样式, 预览与导出一致
            textStyle: TextStyle(fontSize: fontSize, color: color),
            onErrorFallback: (e) => Center(
              child: Text(
                latex,
                style: TextStyle(fontSize: fontSize, color: Colors.red),
              ),
            ),
          );
        } catch (_) {
          return Center(
            child: Text(
              latex,
              style: TextStyle(fontSize: fontSize, color: Colors.red),
            ),
          );
        }
      },
    );
    return FittedBox(fit: BoxFit.contain, child: child);
  }
}

/// 涂鸦渲染 (按归一化坐标叠加笔画到组件尺寸)
class _DoodleView extends StatelessWidget {
  final EditorComponent component;
  const _DoodleView({required this.component});

  @override
  Widget build(BuildContext context) {
    final bg = component.doodleBackground ??
        const EditorBackground(type: EditorBackgroundType.solid);
    return Stack(
      children: [
        Positioned.fill(child: buildDoodleBackgroundWidget(bg, 1, 1)),
        CustomPaint(
          size: Size(component.width, component.height),
          painter: DoodlePainter(
            strokes: component.doodleStrokes ?? [],
            width: component.width,
            height: component.height,
          ),
        ),
      ],
    );
  }
}

/// 涂鸦笔画绘制
class DoodlePainter extends CustomPainter {
  final List<DoodleStroke> strokes;
  final double width;
  final double height;
  const DoodlePainter({
    required this.strokes,
    required this.width,
    required this.height,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      if (s.points.length == 1) {
        // 单点: 画一个圆点
        final p = s.points.first;
        final paint = Paint()
          ..color = Color(s.colorArgb)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(
          Offset(p.x * width, p.y * height),
          (s.width / 2).clamp(0.5, 64),
          paint,
        );
        continue;
      }
      if (s.points.length < 2) continue;
      final paint = Paint()
        ..color = Color(s.colorArgb)
        ..strokeWidth = s.width.clamp(0.5, 64)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      final first = s.points.first;
      final firstP = Offset(first.x * width, first.y * height);
      path.moveTo(firstP.dx, firstP.dy);
      if (s.points.length == 2) {
        final p = s.points[1];
        path.lineTo(p.x * width, p.y * height);
      } else {
        for (int i = 1; i < s.points.length - 1; i++) {
          final cur = s.points[i];
          final next = s.points[i + 1];
          final curP = Offset(cur.x * width, cur.y * height);
          final nextP = Offset(next.x * width, next.y * height);
          final mid = Offset(
            (curP.dx + nextP.dx) / 2,
            (curP.dy + nextP.dy) / 2,
          );
          path.quadraticBezierTo(curP.dx, curP.dy, mid.dx, mid.dy);
        }
        final last = s.points.last;
        path.lineTo(last.x * width, last.y * height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DoodlePainter old) =>
      old.strokes != strokes || old.width != width || old.height != height;
}

/// 工具: 在给定 context 下把任意可截图 widget 渲染为 PNG 字节
///
/// [builder] 构建待截图 widget, 通过 Overlay + RepaintBoundary 屏幕外截图。
Future<Uint8List?> renderWidgetToPng(
  BuildContext context,
  Widget Function(BuildContext) builder, {
  double width = 1080,
  Duration imageLoadTimeout = const Duration(seconds: 5),
}) async {
  OverlayEntry? entry;
  try {
    final overlay = Overlay.of(context, rootOverlay: true);
    final boundaryKey = GlobalKey();
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
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(width: width, child: builder(context)),
            ),
          ),
        ),
      ),
    );
    entry = OverlayEntry(builder: (_) => widget);
    overlay.insert(entry);
    final end = DateTime.now().add(imageLoadTimeout);
    while (DateTime.now().isBefore(end)) {
      WidgetsBinding.instance.scheduleFrame();
      await Future.delayed(const Duration(milliseconds: 200));
    }
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
