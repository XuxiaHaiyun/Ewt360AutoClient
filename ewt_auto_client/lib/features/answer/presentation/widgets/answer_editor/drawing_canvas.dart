/// 涂鸦画板组件，支持自由手绘/虚线/荧光笔/橡皮、撤销重做、图层显隐与缩放。
/// 通过 GlobalKey 调用 DrawingCanvasState.exportPng 导出 PNG 字节。
library;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

Color? _parseHex(String? s) {
  if (s == null) return null;
  final v = s.trim().replaceAll('#', '');
  if (v.length < 6) return null;
  final r = int.parse(v.substring(0, 2), radix: 16);
  final g = int.parse(v.substring(2, 4), radix: 16);
  final b = int.parse(v.substring(4, 6), radix: 16);
  return Color.fromRGBO(r, g, b, 1);
}

/// 画笔模式
enum StrokeMode { solid, dashed, fluorescent }

/// 单条笔画
class _Stroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final StrokeMode mode;
  final bool isEraser;

  _Stroke({
    required this.points,
    required this.color,
    required this.width,
    required this.mode,
    this.isEraser = false,
  });
}

/// 涂鸦画板
///
/// 支持: 自由手绘 / 虚线 / 荧光�?/ 橡皮�?/ 粗细档位 / 颜色色板 + 自定�?/
/// 撤销重做 (20 �? / 清空 (二次确认) / 涂鸦层显�?/ 缩放�?///
/// 通过 [GlobalKey<DrawingCanvasState>] 调用 [exportPng] 导出 PNG 字节�?
class DrawingCanvas extends StatefulWidget {
  final Color backgroundColor;

  const DrawingCanvas({super.key, this.backgroundColor = Colors.white});

  @override
  State<DrawingCanvas> createState() => DrawingCanvasState();
}

class DrawingCanvasState extends State<DrawingCanvas> {
  final List<_Stroke> _strokes = [];
  final List<_Stroke> _redo = [];
  _Stroke? _current;

  Color _penColor = Colors.black;
  double _penWidth = 3;
  StrokeMode _mode = StrokeMode.solid;
  bool _eraser = false;
  bool _layerVisible = true;
  double _scale = 1.0;

  static const List<Color> palette = [
    Colors.black,
    Colors.red,
    Colors.orange,
    Colors.amber,
    Colors.green,
    Colors.teal,
    Colors.blue,
    Colors.indigo,
    Colors.purple,
    Colors.pink,
    Colors.brown,
    Colors.grey,
  ];

  static const List<double> widths = [1, 3, 5, 8, 12];

  bool get canUndo => _strokes.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void _begin(Offset p) {
    if (!_layerVisible) return;
    _current = _Stroke(
      points: [p],
      color: _eraser ? widget.backgroundColor : _penColor,
      width: _eraser ? _penWidth * 3 : _penWidth,
      mode: _mode,
      isEraser: _eraser,
    );
  }

  void _extend(Offset p) {
    if (_current == null) return;
    setState(() => _current!.points.add(p));
  }

  void _end() {
    if (_current == null) return;
    if (_current!.points.length > 1 || !_current!.isEraser) {
      _strokes.add(_current!);
    }
    _redo.clear();
    _current = null;
    setState(() {});
  }

  void undo() {
    if (_strokes.isEmpty) return;
    _redo.add(_strokes.removeLast());
    if (_redo.length > 20) _redo.removeAt(0);
    setState(() {});
  }

  void redo() {
    if (_redo.isEmpty) return;
    _strokes.add(_redo.removeLast());
    setState(() {});
  }

  Future<void> clearWithConfirm(BuildContext context) async {
    if (_strokes.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清空画板'),
        content: const Text('确定要清空全部涂鸦内容吗?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      _strokes.clear();
      _redo.clear();
      setState(() {});
    }
  }

  void toggleLayer() => setState(() => _layerVisible = !_layerVisible);

  Future<Uint8List?> exportPng() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = context.size ?? const Size(800, 600);
    canvas.drawColor(widget.backgroundColor, BlendMode.srcOver);
    _paintTo(canvas, size, _scale);
    final picture = recorder.endRecording();
    final img = await picture.toImage(
      (size.width * _scale).ceil(),
      (size.height * _scale).ceil(),
    );
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  void _paintTo(Canvas canvas, Size size, double scale) {
    if (!_layerVisible) return;
    final all = [..._strokes];
    if (_current != null) all.add(_current!);
    for (final s in all) {
      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..color = s.color
        ..strokeWidth = s.width;
      if (s.mode == StrokeMode.fluorescent) {
        paint.color = s.color.withValues(alpha: 0.45);
        paint.strokeWidth = s.width * 1.6;
      }
      final pts = s.points;
      if (pts.length < 2) {
        if (pts.isNotEmpty) {
          canvas.drawCircle(pts.first, s.width / 2, paint..style = PaintingStyle.fill);
        }
        continue;
      }
      if (s.mode == StrokeMode.dashed) {
        _drawDashed(canvas, pts, paint);
      } else {
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (int i = 1; i < pts.length; i++) {
          path.lineTo(pts[i].dx, pts[i].dy);
        }
        canvas.drawPath(path, paint);
      }
    }
  }

  void _drawDashed(Canvas canvas, List<Offset> pts, Paint paint) {
    const dash = 10.0;
    const gap = 8.0;
    double carry = 0;
    bool drawing = true;
    for (int i = 1; i < pts.length; i++) {
      var a = pts[i - 1];
      final b = pts[i];
      final segLen = (b - a).distance;
      var t = 0.0;
      while (t < segLen) {
        final remain = drawing ? dash - carry : gap - carry;
        final step = min(remain, segLen - t);
        final np = Offset(
          a.dx + (b.dx - a.dx) * (t + step) / segLen,
          a.dy + (b.dy - a.dy) * (t + step) / segLen,
        );
        if (drawing) {
          canvas.drawLine(a, np, paint);
        }
        a = np;
        t += step;
        carry += step;
        if (carry >= (drawing ? dash : gap)) {
          carry = 0;
          drawing = !drawing;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(color: widget.backgroundColor),
        GestureDetector(
          onPanStart: (d) => _begin(d.localPosition),
          onPanUpdate: (d) => _extend(d.localPosition),
          onPanEnd: (_) => _end(),
          child: CustomPaint(
            painter: _CanvasPainter(this),
            size: Size.infinite,
          ),
        ),
            // top toolbar
            Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _buildToolbar(context),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Material(
      color: Colors.black54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              tooltip: '撤销',
              icon: const Icon(Icons.undo, color: Colors.white, size: 20),
              onPressed: canUndo ? undo : null,
            ),
            IconButton(
              tooltip: '重做',
              icon: const Icon(Icons.redo, color: Colors.white, size: 20),
              onPressed: canRedo ? redo : null,
            ),
            IconButton(
              tooltip: _eraser ? '画笔' : 'Eraser',
              icon: Icon(
                _eraser ? Icons.brush : Icons.cleaning_services_outlined,
                color: Colors.white,
                size: 20,
              ),
              onPressed: () => setState(() => _eraser = !_eraser),
            ),
            IconButton(
              tooltip: 'Layer',
              icon: Icon(
                _layerVisible ? Icons.visibility : Icons.visibility_off,
                color: Colors.white,
                size: 20,
              ),
              onPressed: toggleLayer,
            ),
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.delete_outline, color: Colors.white, size: 20),
              onPressed: () => clearWithConfirm(context),
            ),
            // 模式
            DropdownButton<StrokeMode>(
              value: _mode,
              dropdownColor: Colors.grey[800],
              iconEnabledColor: Colors.white,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              items: const [
                DropdownMenuItem(value: StrokeMode.solid, child: Text('实线')),
                DropdownMenuItem(value: StrokeMode.dashed, child: Text('虚线')),
                DropdownMenuItem(value: StrokeMode.fluorescent, child: Text('荧光')),
              ],
              onChanged: (m) => setState(() => _mode = m ?? StrokeMode.solid),
            ),
            // 粗细
            DropdownButton<double>(
              value: _penWidth,
              dropdownColor: Colors.grey[800],
              iconEnabledColor: Colors.white,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              items: [
                for (final w in widths)
                  DropdownMenuItem(value: w, child: Text('${w}px')),
              ],
              onChanged: (w) => setState(() => _penWidth = w ?? 3),
            ),
            // 颜色
            ...palette.map((c) => InkWell(
                  onTap: () => setState(() {
                    _penColor = c;
                    _eraser = false;
                  }),
                  child: Container(
                    width: 20,
                    height: 20,
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: c,
                      border: Border.all(
                        color: _penColor == c && !_eraser
                            ? Colors.white
                            : Colors.transparent,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                )),
            SizedBox(
              width: 70,
              child: TextField(
                style: const TextStyle(color: Colors.white, fontSize: 11),
                decoration: const InputDecoration(
                  hintText: '#RRGGBB',
                  hintStyle: TextStyle(color: Colors.white54, fontSize: 11),
                  isDense: true,
                ),
                onSubmitted: (v) {
                  final col = _parseHex(v);
                  if (col != null) setState(() {
                    _penColor = col;
                    _eraser = false;
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CanvasPainter extends CustomPainter {
  final DrawingCanvasState state;
  _CanvasPainter(this.state);

  @override
  void paint(Canvas canvas, Size size) {
    state._paintTo(canvas, size, state._scale);
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter old) => true;
}

